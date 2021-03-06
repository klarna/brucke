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
        , t_consumer_managed_offset/1
        , t_filter/1
        , t_filter_with_ts/1
        , t_random_dispatch/1
        , t_split_message/1
        , t_route_ratelimiter/1
        , t_route_ratelimiter_change_rate/1
        , t_route_ratelimiter_topic_rate/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("brod/include/brod.hrl").

-define(HOST, "localhost").
-define(HOSTS, [{?HOST, 9092}]).
-define(OFFSETS_TAB, brucke_offsets).

%%%_* ct callbacks =============================================================

suite() -> [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
  NewConfig = prepare_data_t_consumer_managed_offset(Config),
  _ = application:load(brucke),
  application:set_env(brucke, config_file, {priv, "brucke.yml"}),
  {ok, _} = application:ensure_all_started(brucke),
  NewConfig.

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

t_consumer_managed_offset(Config) when is_list(Config) ->
  %%% preconditions are set in prepare_data_t_consumer_managed_offset/1
  Client = client_1,
  UPSTREAM = <<"brucke-filter-consumer-managed-offsets-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-consumer-managed-offsets-test-downstream">>,
  DSOffsets = ?config({DOWNSTREAM, offsets}, Config),
  [ok = wait_for_subscriber(Client, UPSTREAM, P) || {P, _} <- DSOffsets],
  Result = [{P, Msg#kafka_message.value} || {P,O} <- DSOffsets, Msg <- fetch(DOWNSTREAM, P, O)],
  Expected = [ {0, <<"4">>} % partition 0,
             , {0, <<"5">>}
             , {0, <<"6">>}
             , {0, <<"7">>}
             , {0, <<"8">>}
             , {1, <<"15">>} % partition 1
             , {1, <<"16">>}
             , {1, <<"17">>}
             , {1, <<"18">>}
             , {2, <<"26">>} % partition 2
             , {2, <<"27">>}
             , {2, <<"28">>}
             ],
  ?assertEqual(Expected, Result).


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

t_route_ratelimiter(Config) when is_list(Config) ->
  %% Test rate 0 means pause
  UPSTREAM = <<"brucke-ratelimiter-test-upstream">>,
  DOWNSTREAM = <<"brucke-ratelimiter-test-downstream">>,
  Client = client_1,
  ok = wait_for_subscriber(client_3, UPSTREAM),
  ok = brod:start_producer(Client, UPSTREAM, []),
  [brod:produce_sync(Client, UPSTREAM, 0, << "foo" >>, << "bar" >>) || _V <- lists:seq(1,20)],
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  ct:sleep(3000),
  {ok, Offset2} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  %%% in priv/brucke.yml rate is set to 0 msgs/s so no message should be delivered to downstream.
  ?assertEqual(Offset2, Offset),
  ok.

t_route_ratelimiter_change_rate(Config) when is_list(Config) ->
  %% Test we can change the rate via filter restapi
  %% configured in priv/brucke.yml
  UPSTREAM = <<"brucke-ratelimiter-test-upstream">>,
  DOWNSTREAM = <<"brucke-ratelimiter-test-downstream">>,
  Client = client_1,
  Rid = {local_cluster_ssl, 'brucke-ratelimiter-test'},
  ok = wait_for_subscriber(client_3, UPSTREAM),
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  ?assertEqual({1000, 0}, brucke_ratelimiter:get_rate(Rid)),
  set_rate_limiter(Rid, 10),
  ?assertEqual({1000, 10}, brucke_ratelimiter:get_rate(Rid)),
  [brod:produce_sync(Client, UPSTREAM, 0, << "foo" >>, << "bar" >>) || _V <- lists:seq(1,100)],
  timer:sleep(3000),
  {ok, Offset2} = brod:resolve_offset(?HOSTS, DOWNSTREAM, 0, latest),
  Diff = Offset2 - Offset,
  ?assert(Diff < 40 orelse Diff > 20),
  ok.

t_route_ratelimiter_topic_rate(Config) when is_list(Config) ->
  %% Test ratelimit is on topic, not per topic-partition.
  %% configured in priv/brucke.yml
  UPSTREAM = <<"brucke-ratelimiter-test-upstream">>,
  DOWNSTREAM = <<"brucke-ratelimiter-test-downstream">>,
  Client = client_1,
  Rid = {local_cluster_ssl, 'brucke-ratelimiter-test'},
  Partitions = [0, 1, 2],
  GetLatestPartitionOffsets = fun() ->
                                  lists:map(fun(P) ->
                                                {ok, Offset} = brod:resolve_offset(?HOSTS, DOWNSTREAM, P, latest),
                                                Offset
                                            end, Partitions)
                              end,

  ok = wait_for_subscriber(client_3, UPSTREAM),
  ok = brod:start_producer(Client, UPSTREAM, []),

  %%% pause
  set_rate_limiter(Rid, 0),
  ct:sleep(1000),

  ?assertEqual({1000, 0}, brucke_ratelimiter:get_rate(Rid)),

  Offsets0 = GetLatestPartitionOffsets(),

  [brod:produce_sync(Client, UPSTREAM, P, << "foo2" >>, << "bar" >>) || _V <- lists:seq(1, 100), P <- Partitions],

  %% here we also change interval
  set_rate_limiter(Rid, {100,10}),

  ?assertEqual({100, 10}, brucke_ratelimiter:get_rate(Rid)),

  ct:sleep(3000),

  Offsets1 = GetLatestPartitionOffsets(),

  Total = lists:foldl(fun({New, Old}, Acc)->
                          Diff = New - Old,
                          ?assert(Diff > 0),
                          Acc + Diff
                      end, 0, lists:zip(Offsets1, Offsets0)),
  ?assert(Total > 200 andalso Total < 400),
  ok.

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
  wait_for_subscriber(Client, Topic, 0).
wait_for_subscriber(Client, Topic, Partition) ->
  F = fun() ->
          {ok, Pid} = brod:get_consumer(Client, Topic, Partition),
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

prepare_data_t_consumer_managed_offset(Config) ->
  Client = client_prepare_data,
  UPSTREAM =   <<"brucke-filter-consumer-managed-offsets-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-consumer-managed-offsets-test-downstream">>,
  ConsumerGroup = <<"brucke-filter-test-consumer-managed-offsets">>,
  {ok,_} = application:ensure_all_started(brod),
  Partitions = [0, 1, 2],
  Messages = [4, 5, 6, 7, 8],
  DSOffsets = resolve_offsets(DOWNSTREAM, Partitions),
  USOffsets = resolve_offsets(UPSTREAM, Partitions),
  ct:pal("PartitionOffsets for ~p are ~p", [UPSTREAM, USOffsets]),
  case USOffsets of
    [{0, 0}, {1, 0}, {2, 0}] -> % kafka is empty. this is new test env, produce test data
      ct:pal("insert test msgs to topic ~p", [UPSTREAM]),
      ok = brod:start_client(?HOSTS, Client),
      ok = brod:start_producer(Client, UPSTREAM, _ProducerConfig = []),
      [ ok = brod:produce_sync(Client, UPSTREAM, P, <<>>, integer_to_binary(P*10 + M)) ||
        P <- Partitions,
        M <- Messages],
      ok = brod:stop_client(Client);
    _ ->
      skip
  end,
  ok = prepare_brucke_offsets_dets(ConsumerGroup, UPSTREAM, USOffsets),
  [{{DOWNSTREAM, offsets}, DSOffsets}  | Config].

prepare_brucke_offsets_dets(GroupId, Topic, PartitionOffsets) ->
  {ok, ?OFFSETS_TAB} = dets:open_file(?OFFSETS_TAB,
                                        [{file, "/tmp/brucke_offsets_ct.DETS"},
                                         {ram_file, true}]),
  {Partitions, _Offsets} = lists:unzip(PartitionOffsets),
  TestOffsets = [-1, 0, 1], %% because brod coordinator will do offset+1
  lists:foreach(fun({Partition, Offset}) ->
                    ok = dets:insert(?OFFSETS_TAB, {{GroupId, Topic, Partition}, Offset})
                end, lists:zip(Partitions, TestOffsets)),
  ok = dets:close(?OFFSETS_TAB).

resolve_offsets(Topic, Partitions) ->
  lists:map(fun(P) ->
                {ok, Offset} = brod:resolve_offset(?HOSTS, Topic, P, latest),
                {P, Offset}
            end, Partitions).

set_rate_limiter(Rid, MsgPerSec) when is_integer(MsgPerSec)->
  set_rate_limiter(Rid, {1000, MsgPerSec});
set_rate_limiter({Cluster, Cgid}, {I, T}) ->
  RatelimiterApiUrl = lists:flatten(io_lib:format("http://localhost:~p/plugins/ratelimiter/~s/~s",
                                                  [brucke_app:http_port(), Cluster, Cgid])),
  Body = jsone:encode([ {interval, I}
                      , {threshold, T}]),
  {ok, {{"HTTP/1.1",200,"OK"}, _, "\"ok\"" }} =
    httpc:request(post, {RatelimiterApiUrl, [{"Accept", "application/json"}],
                         "application/json", Body}, [], []).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
