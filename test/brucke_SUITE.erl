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
  _ = application:ensure_all_started(brucke),
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
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  V0 = uniq_int(),
  V1 = uniq_int(),
  V2 = uniq_int(),
  Headers = [{<<"foo">>, <<"bar">>}],
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"0">>, bin(V0)),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"1">>, bin(V1)),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"2">>, #{value => bin(V2),
                                                         headers => Headers}),
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, V0, Offset, _TryMax = 20, [], _Count = 3),
  ?assertMatch([{_, 0, V0},
                {_, 1, V1},
                {_, 2, V2, Headers}], Messages).

%% Send 3 messages to upstream topic
%% Expect them to be mirrored to downstream toicp with below filtering logic
%% When the key integer's mod-3 is a remainder
%% 0: message is forwarded as-is to downstream
%% 1: message is discarded
%% 2: value integer is transformed with '+ 1' then forwarded to downstream.
%%
%% Assume brucket application is started using `priv/brucke.yml'
t_filter(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-filter-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  V0 = uniq_int(),
  V1 = uniq_int(),
  V2 = uniq_int(),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"0">>, bin(V0)), %% as is
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"1">>, bin(V1)), %% ignore
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"2">>, bin(V2)), %% mutate
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, V0, Offset, _TryMax = 20, [], 2),
  V3 = V2 + 1, %% transformed
  ?assertMatch([{_T0, 0, V0}, %% as is
                %% 1 is discarded
                {_T2, 2, V3} %% transformed
               ], Messages).

t_filter_with_ts(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-filter-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  T0 = ts(),
  K0 = <<"40">>,
  I0 = uniq_int(),
  V0 = [{T0, K0, bin(I0)}],
  K1 = <<"41">>,
  I1 = uniq_int(),
  V1 = [{ts(), K1, bin(I1)}],
  T2 = ts(),
  K2 = <<"42">>,
  I2 = uniq_int(),
  V2 = [{T2, K2, bin(I2)}],
  ok = brod:produce_sync(Client, UPSTREAM, 0, K0, V0), %% as is
  ok = brod:produce_sync(Client, UPSTREAM, 0, K1, V1), %% ignore
  ok = brod:produce_sync(Client, UPSTREAM, 0, K2, V2), %% mutate
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, I0, Offset, _TryMax = 20, [], 2),
  ?assertEqual([{T0, 40, I0}, %% as is
                %% 1 is discarded
                {T2, 42, I2 + 1} %% transformed
               ], Messages).

t_random_dispatch(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-filter-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  T = ts(),
  Msg = #{ts => T, key => <<"50">>, value => <<"51">>},
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<>>, [Msg]),
  FetchFun = fun(Of) -> fetch(DOWNSTREAM, 0, Of) end,
  Messages = fetch_loop(FetchFun, 50, Offset, _TryMax = 20, [], 2),
  ?assertMatch([{T, 50, 51}], Messages).

%%%_* Help functions ===========================================================

fetch(Topic, Partition, Offset) ->
  Options = [{query_api_versions, true}],
  brod:fetch(?HOSTS, Topic, Partition, Offset, 1000, 10, 1000, Options).

ts() -> os:system_time() div 1000000.

fetch_loop(_F, _V0, _Offset, N, Acc, C) when N =< 0 orelse C =< 0 -> Acc;
fetch_loop(F, V0, Offset, N, Acc, Count) ->
  case F(Offset) of
    {ok, []} ->
      fetch_loop(F, V0, Offset, N - 1, Acc, Count);
    {ok, Msgs0} ->
      Msgs =
        lists:filtermap(
          fun(#kafka_message{ key = Key
                            , ts = Ts
                            , value = Value
                            , headers = Headers
                            }) ->
              case int(Value) >= V0 of
                true when Headers =:= [] -> {true, {Ts, int(Key), int(Value)}};
                true -> {true, {Ts, int(Key), int(Value), Headers}};
                false -> false
              end
          end, Msgs0),
      C = length(Msgs),
      fetch_loop(F, V0, Offset + C, N - 1, Acc ++ Msgs, Count - C)
  end.

uniq_int() -> os:system_time().

bin(X) -> integer_to_binary(X).
int(B) -> binary_to_integer(B).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
