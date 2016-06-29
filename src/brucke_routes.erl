%%%
%%%   Copyright (c) 2016 Klarna AB
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
-module(brucke_routes).

-export([ all/0
        , destroy/0
        , init/1
        , lookup/2
        ]).

-include("brucke_int.hrl").

-define(ETS, ?MODULE).

-define(IS_PRINTABLE(C), (C >= 32 andalso C < 127)).

-define(IS_VALID_TOPIC_NAME(N),
        (is_atom(N) orelse
         is_binary(N) orelse
         is_list(N) andalso N =/= [] andalso ?IS_PRINTABLE(hd(N)))).

%%%_* APIs =====================================================================

-spec init([proplists:proplist()]) -> ok | no_return().
init(Routes) when is_list(Routes) ->
  ets:info(?ETS) =/= ?undef andalso exit({?ETS, already_created}),
  ?ETS = ets:new(?ETS, [named_table, protected, set, {keypos, #route.upstream}]),
  try
    ok = do_init_loop(Routes)
  catch C : E ->
    ok = destroy(),
    erlang:C({E, erlang:get_stacktrace()})
  end;
init(Other) ->
  lager:emergency("Expecting list of routes, got ~P", [Other, 9]),
  erlang:exit(bad_routes_config).

%% @doc Lookup in config cache for the message routing destination.
-spec lookup(brod_client_id(), kafka_topic()) -> route() | false.
lookup(UpstreamClientId, UpstreamTopic) ->
  case ets:lookup(?ETS, {UpstreamClientId, UpstreamTopic}) of
    []      -> false;
    [Route] -> Route
  end.

%% @doc Delete Ets.
-spec destroy() -> ok.
destroy() ->
  try
    ets:delete(?ETS),
    ok
  catch error : badarg ->
    ok
  end.

%% @doc Get all routes from cache.
-spec all() -> [route()].
all() -> ets:tab2list(?ETS).

%%%_* Internal functions =======================================================

-spec do_init_loop([proplists:proplist()]) -> ok.
do_init_loop([]) -> ok;
do_init_loop([RawRoute | Rest]) ->
  case validate_route(RawRoute) of
    {ok, Routes} ->
      ok = insert_routes(Routes);
    {error, Reasons} ->
      Rs = [[Reason, "\n"] || Reason <- Reasons],
      ok = brucke_lib:log_skipped_route_alert(RawRoute, Rs)
  end,
  do_init_loop(Rest).

-spec validate_route(proplists:proplist()) -> {ok, [route()]} | {error, [binary()]}.
validate_route(Route) ->
  {_, UpstreamClientId} = lists:keyfind(upstream_client, 1, Route),
  {_, DownstreamClientId} = lists:keyfind(downstream_client, 1, Route),
  {_, UpstreamTopics} = lists:keyfind(upstream_topics, 1, Route),
  {_, DownstreamTopic} = lists:keyfind(downstream_topic, 1, Route),
  RepartitioningStrategy = proplists:get_value(repartitioning_strategy,
                                               Route, ?DEFAULT_REPARTITIONING_STRATEGY),
  ProducerConfig = proplists:get_value(producer_config, Route, []),
  ConsumerConfig = proplists:get_value(consumer_config, Route, []),
  MaxPartitionsPerGroupMember = proplists:get_value(max_partitions_per_group_member,
                                                    Route, ?MAX_PARTITIONS_PER_GROUP_MEMBER),
  ValidationResults0 =
    [ is_configured_client_id(UpstreamClientId) orelse
        <<"unknown upstream client id">>
    , is_configured_client_id(DownstreamClientId) orelse
        <<"unknown downstream client id">>
    , ?IS_VALID_TOPIC_NAME(DownstreamTopic) orelse
        invalid_topic_name(downstream, DownstreamTopic)
    , validate_upstream_topics(UpstreamClientId, UpstreamTopics)
    , ?IS_VALID_REPARTITIONING_STRATEGY(RepartitioningStrategy) orelse
          fmt("unknown repartitioning strategy ~p", [RepartitioningStrategy])
    , (is_integer(MaxPartitionsPerGroupMember) andalso MaxPartitionsPerGroupMember > 0) orelse
          fmt("max_partitions_per_group_member should be a positive integer", [])
    ],
  ValidationResults = lists:flatten(ValidationResults0),
  case [Result || Result <- ValidationResults, Result =/= true] of
    [] ->
      ok = ensure_no_loopback(UpstreamClientId, DownstreamClientId, UpstreamTopics, DownstreamTopic),
      Options = #{ repartitioning_strategy => RepartitioningStrategy
                 , producer_config => ProducerConfig
                 , consumer_config => ConsumerConfig
                 , max_partitions_per_group_member => MaxPartitionsPerGroupMember},
      MapF = fun(Topic) ->
                 #route{ upstream = {UpstreamClientId, topic(Topic)}
                       , downstream = {DownstreamClientId, topic(DownstreamTopic)}
                       , options = Options}
             end,
      {ok, lists:map(MapF, UpstreamTopics)};
    Reasons ->
      {error, Reasons}
  end.

ensure_no_loopback(ClientId, ClientId, UpstreamTopics, DownstreamTopic) ->
  ensure_no_loopback(UpstreamTopics, DownstreamTopic);
ensure_no_loopback(_UpstreamClientId, _DownstreamClientId, _UpstreamTopics, _DownstreamTopic) ->
  ok.

%% This is to ensure there is no direct loopback due to typo for example.
%% indirect loopback would be fun for testing, so not trying to build a graph
%% {upstream, topic_1} -> {downstream, topic_2}
%% {downstream, topic_2} -> {upstream, topic_1}
%% you get a perfect data generator for load testing.
-spec ensure_no_loopback(topic_name() | [topic_name()], topic_name()) ->
        ok | {error, binary()}.
ensure_no_loopback(UpstreamTopics, DownstreamTopic) ->
  case lists:member(topic(DownstreamTopic), topics(UpstreamTopics)) of
    true ->
      {error, [<<"direct loopback from upstream topic to downstream topic">>]};
    false ->
      ok
  end.

-spec insert_routes([route()]) -> ok.
insert_routes(Routes) ->
  true = ets:insert(?ETS, Routes),
  ok.

-spec is_configured_client_id(brod_client_id()) -> boolean().
is_configured_client_id(ClientId) ->
  brucke_config:is_configured_client_id(ClientId).

-spec validate_upstream_topics(brod_client_id(),
                               topic_name() | [topic_name()]) -> [binary()].
validate_upstream_topics(_ClientId, []) ->
  invalid_topic_name(upstream, []);
validate_upstream_topics(ClientId, Topic) when ?IS_VALID_TOPIC_NAME(Topic) ->
  validate_upstream_topic(ClientId, Topic);
validate_upstream_topics(ClientId, Topics0) when is_list(Topics0) ->
  case lists:partition(fun(T) -> ?IS_VALID_TOPIC_NAME(T) end, Topics0) of
    {Topics, []} ->
      [validate_upstream_topic(ClientId, T) || T <- Topics];
    {_, InvalidTopics} ->
      invalid_topic_name(upstream, InvalidTopics)
  end.

-spec validate_upstream_topic(brod_client_id(), topic_name()) ->
        [true | binary()].
validate_upstream_topic(ClientId, Topic) ->
  ClientIds = lookup_upstream_client_ids_by_topic(Topic),
  ClusterName = brucke_config:get_cluster_name(ClientId),
  lists:map(
    fun(Id) ->
      case ClusterName =:= brucke_config:get_cluster_name(Id) of
        true ->
          fmt("Duplicated route for upstream topic ~s in cluster ~s. "
              "This means you are trying to bridge one upstream topic to "
              "two or more downstream topics. If this is a valid use case "
              "(not misconfiguration), a workaround is to make a copy of the "
              "upstream cluster with a different name assigned.",
              [Topic, ClusterName]);
        false ->
          true
      end
    end, ClientIds).

-spec lookup_upstream_client_ids_by_topic(topic_name()) -> [brod_client_id()].
lookup_upstream_client_ids_by_topic(Topic) ->
  lists:foldl(
    fun(#route{upstream = {ClientId, Topic_}}, Acc) ->
      case Topic_ =:= topic(Topic) of
        true  -> [ClientId | Acc];
        false -> Acc
      end
    end, [], all()).

-spec invalid_topic_name(upstream | downstream, any()) -> binary().
invalid_topic_name(UpOrDown_stream, NameOrList) ->
  fmt("expecting ~p topic(s) to be (a list of) atom() | string() | binary()\n"
      "got: ~p", [UpOrDown_stream, NameOrList]).

%% @private Accept atom(), string(), or binary() as topic name,
%% unified to binary().
%% @end
-spec topic(topic_name()) -> kafka_topic().
topic(Topic) when is_atom(Topic)   -> topic(atom_to_list(Topic));
topic(Topic) when is_binary(Topic) -> Topic;
topic(Topic) when is_list(Topic)   -> list_to_binary(Topic).

-spec topics(topic_name() | [topic_name()]) -> [kafka_topic()].
topics(TopicName) when ?IS_VALID_TOPIC_NAME(TopicName) ->
  [topic(TopicName)];
topics(TopicNames) when is_list(TopicNames) ->
  [topic(T) || T <- TopicNames].

-spec fmt(string(), [term()]) -> binary().
fmt(Fmt, Args) -> iolist_to_binary(io_lib:format(Fmt, Args)).

%%%_* Tests ====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

no_ets_leak_test() ->
  clean_setup(),
  L = ets:all(),
  ?assertNot(lists:member(?ETS, L)),
  try
    init([a|b])
  catch _ : _ ->
    ?assertEqual(L, ets:all())
  end.

client_not_configured_test() ->
  clean_setup(false),
  Route1 = {{client_2, topic_1}, {client_2, topic_2}, []},
  ok = init([Route1]),
  ?assertEqual([], all()),
  ok = destroy().

bad_topic_name_test() ->
  clean_setup(),
  Route1 = {{client_1, topic_1}, {client_1, [topic_1]}, []},
  Route2 = {{client_1, [topic_1]}, {client_1, ["topic_x"]}, []},
  Route3 = {{client_1, []}, {client_1, topic_1}, []},
  Route4 = {{client_1, [[]]}, {client_1, topic_1}, []},
  ok = init([Route1, Route2, Route3, Route4]),
  ?assertEqual([], all()),
  ok = destroy().

bad_routing_options_test() ->
  clean_setup(),
  Routes = [ {{client_1, topic_1}, {client_1, topic_2}, #{a => b}}
           , {{client_1, topic_1}, {client_1, topic_2},
              [{repartitioning_strategy, x}]}
           , {{client_1, topic_1}, {client_1, topic_2}, [{producer_config, x}]}
           , {{client_1, topic_1}, {client_1, topic_2}, [{consumer_config, x}]}
           , {{client_1, topic_1}, {client_1, topic_2},
              [{max_partitions_per_subscriber, x}]}
           ],
  ok = init(Routes),
  ?assertEqual([], all()),
  ok = destroy().

duplicated_source_test() ->
  clean_setup(),
  ValidRoute = {{client_1, [<<"topic_1">>, "topic_2"]},
                {client_1, <<"topic_3">>}, #{}},
  Routes = [ValidRoute
           ,{{client_1, topic_1}, {client_1, topic_3}, []}],
  ok = init(Routes),
  ?assertEqual([ {{client_1, <<"topic_1">>}, {client_1, <<"topic_3">>}, #{}}
               , {{client_1, <<"topic_2">>}, {client_1, <<"topic_3">>}, #{}}
               ], all_sorted()),
  ?assertEqual({{client_1, <<"topic_1">>}, {client_1, <<"topic_3">>}, #{}},
               lookup(client_1, <<"topic_1">>)),
  ok = destroy().

direct_loopback_test() ->
  clean_setup(),
  Routes = [ {{client_1, topic_1}, {client_1, topic_1}, []}
           , {{client_1, topic_1}, {client_2, topic_2}, []}
           ],
  ok = init(Routes),
  ?assertEqual([{{client_1, <<"topic_1">>}, {client_2, <<"topic_2">>}, #{}}],
               all()),
  ok = destroy().

bad_config_test() ->
  ?assertException(exit, bad_routes_config, init(<<"not a list">>)).

clean_setup() -> clean_setup(true).

clean_setup(IsConfiguredClientId) ->
  ok = destroy(),
  try
    meck:unload(brucke_config)
  catch _:_ ->
    ok
  end,
  meck:new(brucke_config, [no_passthrough_cover]),
  meck:expect(brucke_config, is_configured_client_id, 1, IsConfiguredClientId),
  meck:expect(brucke_config, get_cluster_name, 1, <<"group-id">>),
  ok.

all_sorted() -> lists:keysort(1, all()).

-endif.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
