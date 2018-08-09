%%%
%%%   Copyright (c) 2017-2018 Klarna Bank AB (publ)
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%

%% @private
-module(brucke_SUITE).

%% Test framework
-export([ init_per_suite/1
        , end_per_suite/1
        , init_per_testcase/2
        , end_per_testcase/2
        , all/0
        , suite/0
        ]).

%% Test cases
-export([ t_basic/1
        , t_filter/1
        , t_filter_with_ts/1
        , t_random_dispatch/1
        , t_split_message/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("brod/include/brod.hrl").

-define(HOST, "localhost").
-define(HOSTS, [{?HOST, 9092}]).

%%%_* ct callbacks =============================================================

suite() -> [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
  _ = application:load(brucke),
  application:set_env(brucke, config_file, {priv, "brucke.yml"}),
  {ok, _} = application:ensure_all_started(brucke),
  Config.

end_per_suite(_Config) ->
  application:stop(brucke),
  application:stop(brod),
  ok.

init_per_testcase(Case, Config) ->
  try
    ?MODULE:Case({init, Config})
  catch
    error : function_clause ->
      Config
  end.

end_per_testcase(Case, Config) ->
  try
    ?MODULE:Case({'end', Config})
  catch
    error : function_clause ->
      ok
  end,
  ok.

all() -> [F || {F, _A} <- module_info(exports),
                  case atom_to_list(F) of
                    "t_" ++ _ -> true;
                    _         -> false
                  end].

%%%_* Test functions ===========================================================

t_basic(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-basic-test-upstream">>,
  DOWNSTREAM = <<"brucke-basic-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = wait_for_subscriber(Client, UPSTREAM),
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  Headers = [{<<"foo">>, <<"bar">>}],
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<>>, <<"v0">>),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<>>, <<"v1">>),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<>>,
                         #{value => <<"v2">>, headers => Headers}),
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, Offset, _TryMax = 20, [], _Count = 3),
  ?assertMatch([{_, <<"v0">>},
                {_, <<"v1">>},
                {_, <<"v2">>, Headers}], Messages).

%% Send 3 messages to upstream topic
%% Expect them to be mirrored to downstream toicp with filter/transformation
%% logic implemented in `brucke_test_filter' module. see config `priv/brucke.yml'
t_filter(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-filter-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = wait_for_subscriber(client_3, UPSTREAM),
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"as_is">>, <<"0">>),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"discard">>, <<"1">>),
  V = uniq_int(),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"increment">>, bin(V)),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"append_state">>, <<"foo">>),
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, Offset, _TryMax = 20, [], 2),
  NewV = bin(V + 1),
  ?assertMatch([{_T0, <<"0">>},
                {_T2, NewV},
                {_T3, <<"foo 3">>}
               ], Messages).

t_filter_with_ts(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-filter-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = wait_for_subscriber(client_3, UPSTREAM),
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  T0 = ts(),
  I0 = uniq_int(),
  V0 = #{ts => T0, value => bin(I0)},
  I1 = uniq_int(),
  V1 = #{value => bin(I1)},
  T2 = T0 + 1,
  I2 = uniq_int(),
  V2 = #{ts => T2, value => bin(I2)},
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"as_is">>, V0),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"discard">>, V1),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"increment">>, V2),
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, Offset, _TryMax = 20, [], 2),
  ?assertEqual([{T0, bin(I0)}, {T2, bin(I2 + 1)}], Messages).

t_random_dispatch(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-filter-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = wait_for_subscriber(client_3, UPSTREAM),
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  T = ts(),
  Msg = #{ts => T, key => <<"as_is">>, value => <<"51">>},
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<>>, [Msg]),
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, Offset, _TryMax = 20, [], 1),
  ?assertMatch([{T, <<"51">>}], Messages).

t_split_message(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-filter-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = wait_for_subscriber(client_3, UPSTREAM),
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  T = ts(),
  Msg = #{ts => T, key => <<"split_value">>, value => <<"a,b,c">>},
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<>>, [Msg]),
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, Offset, _TryMax = 20, [], 3),
  ?assertMatch([{_, <<"a">>},
                {_, <<"b">>},
                {_, <<"c">>}], Messages).

%%%_* Help functions ===========================================================

%% wait for subsceriber of the upstream topic
wait_for_subscriber(Client, Topic) ->
  F = fun() ->
          {ok, Pid} = brod:get_consumer(Client, Topic, _Partition = 0),
          {error, {already_subscribed_by, _}} =
            brod_consumer:subscribe(Pid, fake_subscriber, []),
          exit(normal)
      end,
  {Pid, Mref} = erlang:spawn_monitor(fun() -> wait_for_subscriber(F) end),
  receive
    {'DOWN', Mref, process, Pid, normal} ->
      ok;
    {'DOWN', Mref, process, Pid, Reason} ->
      ct:fail(Reason)
  after
    20000 ->
      exit(Pid, kill),
      error(timeout)
  end.

wait_for_subscriber(F) ->
  try
    F()
  catch
    error : _Reason ->
      timer:sleep(1000),
      wait_for_subscriber(F)
  end.

fetch(Topic, Partition, Offset) ->
  {ok, {_HwOffset, Messages}} =
    brod:fetch({?HOSTS, []}, Topic, Partition, Offset),
  Messages.

ts() -> os:system_time() div 1000000.

fetch_loop(_F, _Offset, N, Acc, C) when N =< 0 orelse C =< 0 -> Acc;
fetch_loop(F, Offset, N, Acc, Count) ->
  case F(Offset) of
    [] -> fetch_loop(F, Offset, N - 1, Acc, Count);
    Msgs0 ->
      Msgs =
        lists:map(
          fun(#kafka_message{ ts = Ts
                            , value = Value
                            , headers = Headers
                            }) ->
              case Headers =:= [] of
                true -> {Ts, Value};
                false -> {Ts, Value, Headers}
              end
          end, Msgs0),
      C = length(Msgs),
      fetch_loop(F, Offset + C, N - 1, Acc ++ Msgs, Count - C)
  end.

uniq_int() -> os:system_time().

bin(X) -> integer_to_binary(X).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
