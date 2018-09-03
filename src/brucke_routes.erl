%%%
%%%   Copyright (c) 2016-2018 Klarna Bank AB (publ)
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
        , init/1
        , health_status/0
        , get_cg_id/1
        , add_skipped_route/2
        ]).

-include("brucke_int.hrl").

-define(T_ROUTES, brucke_routes).
-define(T_DISCARDED_ROUTES, brucke_discarded_routes).

-define(IS_PRINTABLE(C), (C >= 32 andalso C < 127)).

-define(IS_VALID_TOPIC_NAME(N),
        (is_atom(N) orelse
         is_binary(N) orelse
         is_list(N) andalso N =/= [] andalso ?IS_PRINTABLE(hd(N)))).

-define(NO_CG_ID_OPTION, ?undef).

-type raw_cg_id() :: ?undef | atom() | string() | binary().
-type cg_id() :: binary().

%%%_* APIs =====================================================================

-spec init([raw_route()]) -> ok | no_return().
init(Routes) when is_list(Routes) ->
  ets:info(?T_ROUTES) =/= ?undef andalso exit({?T_ROUTES, already_created}),
  ets:info(?T_DISCARDED_ROUTES) =/= ?undef andalso exit({?T_DISCARDED_ROUTES, already_created}),
  %% set table, allow no entry duplication
  ets:new(?T_ROUTES, [named_table, public, set,
                      {keypos, #route.upstream}]),
  ets:new(?T_DISCARDED_ROUTES, [named_table, public, bag]),
  try
    ok = do_init_loop(Routes)
  catch C : E ?BIND_STACKTRACE(Stack)  ->
    ?GET_STACKTRACE(Stack),
    ok = destroy(),
    erlang:C({E, Stack})
  end;
init(Other) ->
  lager:emergency("Expecting list of routes, got ~P", [Other, 9]),
  erlang:exit(bad_routes_config).

%% @doc Delete Ets.
-spec destroy() -> ok.
destroy() ->
  try
    ets:delete(?T_ROUTES),
    ets:delete(?T_DISCARDED_ROUTES),
    ok
  catch error : badarg ->
    ok
  end.

%% @doc Get all routes from cache.
-spec all() -> [route()].
all() ->
  ets:tab2list(?T_ROUTES).

%% @doc Routes health status, returns lists of healthy, unhealthy and discarded routes
-spec health_status() -> maps:map().
health_status() ->
  {Healthy0, Unhealthy0} = lists:partition(fun is_healthy/1, all()),
  Healthy = lists:map(fun format_route/1, Healthy0),
  Unhealthy = lists:map(fun format_route/1, Unhealthy0),
  Discarded = lists:map(fun format_skipped_route/1,
                        ets:tab2list(?T_DISCARDED_ROUTES)),
  #{healthy => Healthy, unhealthy => Unhealthy, discarded => Discarded}.

%% @doc Get upstream consumer group ID from rout options.
%% If no `upstream_cg_id' configured, build it from cluster name.
%% @end
-spec get_cg_id(route_options()) -> cg_id().
get_cg_id(Options) ->
  maps:get(upstream_cg_id, Options).

%% @doc Add skipped routes found during or after initialization phase.
%% e.g. Bad topic name found during init validation,
%% or when the route worker finds out the upstream or downstream topic does not exist.
%% @end
-spec add_skipped_route(route() | raw_route(), iolist()) -> ok.
add_skipped_route(Route, Reason) ->
  case Route of
    #route{} ->
      %% delete from healthy routes table
      _ = ets:delete(?T_ROUTES, Route#route.upstream);
    _ ->
      ok
  end,
  %% insert to discarded table
  ets:insert(?T_DISCARDED_ROUTES, {Route, iolist_to_binary(Reason)}),
  brucke_lib:log_skipped_route_alert(Route, Reason),
  ok.

%%%_* Internal functions =======================================================

%% @private
format_route(#route{} = R) ->
  {UpClient, UpTopics} = R#route.upstream,
  {DnClient, DnTopic} = R#route.downstream,
  #{upstream => #{endpoints => endpoints_to_maps(brucke_config:get_client_endpoints(UpClient)),
                  topics => UpTopics},
    downstream => #{endpoints => endpoints_to_maps(brucke_config:get_client_endpoints(DnClient)),
                    topic => DnTopic},
    options => R#route.options}.

%% @private
format_skipped_route({R, Reason}) when is_list(R) ->
  UpClient = proplists:get_value(upstream_client, R),
  UpTopics = lists:map(fun(T) -> list_to_binary(T) end, proplists:get_value(upstream_topics, R, [])),
  DnClient = proplists:get_value(downstream_client, R),
  DnTopic = list_to_binary(proplists:get_value(downstream_topic, R, "")),
  ExceptOptsKeys = [upstream_client, upstream_topics, downstream_client, downstream_topic],
  #{upstream => #{endpoints => endpoints_to_maps(brucke_config:get_client_endpoints(UpClient)),
                  topics => UpTopics},
    downstream => #{endpoints => endpoints_to_maps(brucke_config:get_client_endpoints(DnClient)),
                    topic => DnTopic},
    reason => Reason,
    options => format_raw_options(R, ExceptOptsKeys)
   };
format_skipped_route({#route{} = Route, Reason}) ->
  Map = format_route(Route),
  Map#{reason => Reason};
format_skipped_route({X, Reason}) ->
  fmt("invalid route specification ~p\nreason:~s", [X, Reason]).

%% @private
format_raw_options([], _ExceptOptsKeys) -> [];
format_raw_options([{K, V} | Rest], ExceptOptsKeys) ->
  case lists:member(K, ExceptOptsKeys) of
    true -> format_raw_options(Rest, ExceptOptsKeys);
    false -> [{K, bin_str(V)} | format_raw_options(Rest, ExceptOptsKeys)]
  end.

%% @private
bin_str(L) when is_list(L) -> erlang:iolist_to_binary(L);
bin_str(X) -> X.

%% @private
endpoints_to_maps(Endpoints) ->
  lists:map(fun({Host, Port}) -> #{host => list_to_binary(Host), port => Port} end, Endpoints).

%% @private
-spec is_healthy(route()) -> boolean().
is_healthy(#route{upstream = U}) ->
  Members = brucke_sup:get_group_member_children(U),
  lists:all(
    fun({_Id, Pid}) ->
        is_pid(Pid) andalso brucke_member:is_healthy(Pid)
    end, Members).

-spec do_init_loop([raw_route()]) -> ok.
do_init_loop([]) -> ok;
do_init_loop([RawRoute | Rest]) ->
  try
    case validate_route(RawRoute) of
      {ok, Routes} ->
        ets:insert(?T_ROUTES, Routes);
      {error, Reasons} ->
        Rs = [[Reason, "\n"] || Reason <- Reasons],
        add_skipped_route(RawRoute, Rs)
    end
  catch throw : Reason ->
      ReasonTxt = io_lib:format("~p", [Reason]),
      add_skipped_route(RawRoute, ReasonTxt)
  end,
  do_init_loop(Rest).

-spec validate_route(raw_route()) -> {ok, [route()]} | {error, [binary()]}.
validate_route(RawRoute0) ->
  %% use maps to ensure
  %% 1. key-value list
  %% 2. later value should overwrite earlier in case of key duplication
  RawRouteMap =
    try
      maps:from_list(RawRoute0)
    catch error : badarg ->
        throw(bad_route)
    end,
  RawRoute = maps:to_list(RawRouteMap),
  case apply_route_schema(RawRoute, schema(), defaults(), #{}, []) of
    {ok, #{ upstream_client   := UpstreamClient
          , downstream_client := DownstreamClient
          , upstream_topics   := UpstreamTopics
          , downstream_topic  := DownstreamTopic
          } = RouteAsMap} ->
      case UpstreamClient =:= DownstreamClient of
        true  -> ok = ensure_no_loopback(UpstreamTopics, DownstreamTopic);
        false -> ok
      end,
      {ok, convert_to_route_record(RouteAsMap)};
    {error, Reasons} ->
      {error, Reasons}
  end.

convert_to_route_record(Route) ->
  #{ upstream_client := UpstreamClientId
   , upstream_topics := UpstreamTopics
   , downstream_client := DownstreamClientId
   , downstream_topic := DownstreamTopic
   , repartitioning_strategy := RepartitioningStrategy
   , max_partitions_per_group_member := MaxPartitionsPerGroupMember
   , filter_module := FilterModule
   , filter_init_arg := FilterInitArg
   , default_begin_offset := BeginOffset
   , compression := Compression
   , required_acks := RequiredAcks
   , upstream_cg_id := RawCgId
   , offset_commit_policy := OffsetCommitPolicy
   } = Route,
  ProducerConfig = [{compression, Compression},
                    {required_acks, required_acks(RequiredAcks)}],
  ConsumerConfig = [{begin_offset, BeginOffset}],
  Options =
    #{ repartitioning_strategy => RepartitioningStrategy
     , max_partitions_per_group_member => MaxPartitionsPerGroupMember
     , filter_module => FilterModule
     , filter_init_arg => FilterInitArg
     , producer_config => ProducerConfig
     , consumer_config => ConsumerConfig
     , upstream_cg_id => mk_cg_id(UpstreamClientId, RawCgId)
     , offset_commit_policy => OffsetCommitPolicy
     },
  %% flatten out the upstream topics
  %% to simplify the config as if it's all
  %% one upstream topic to one downstream topic mapping
  MapF =
    fun(Topic) ->
        #route{ upstream = {UpstreamClientId, topic(Topic)}
              , downstream = {DownstreamClientId, topic(DownstreamTopic)}
              , options = Options}
    end,
  lists:map(MapF, topics(UpstreamTopics)).

%% @private
required_acks(all) -> -1;
required_acks(leader) -> 1;
required_acks(none) -> 0;
required_acks(Number) -> Number.

%% @private
defaults() ->
  #{ repartitioning_strategy         => ?DEFAULT_REPARTITIONING_STRATEGY
   , max_partitions_per_group_member => ?MAX_PARTITIONS_PER_GROUP_MEMBER
   , default_begin_offset            => ?DEFAULT_DEFAULT_BEGIN_OFFSET
   , compression                     => ?DEFAULT_COMPRESSION
   , required_acks                   => ?DEFAULT_REQUIRED_ACKS
   , filter_module                   => ?DEFAULT_FILTER_MODULE
   , filter_init_arg                 => ?DEFAULT_FILTER_INIT_ARG
   , upstream_cg_id                  => ?NO_CG_ID_OPTION
   , offset_commit_policy            => ?DEFAULT_OFFSET_COMMIT_POLICY
   }.

schema() ->
  #{ upstream_client =>
       fun(_, Id) ->
           is_configured_client_id(Id) orelse
             <<"unknown upstream client id">>
       end
   , downstream_client =>
       fun(_, Id) ->
           is_configured_client_id(Id) orelse
             <<"unknown downstream client id">>
       end
   , downstream_topic =>
       fun(_, Topic) ->
           ?IS_VALID_TOPIC_NAME(Topic) orelse
             invalid_topic_name(downstream, Topic)
       end
   , upstream_topics =>
       fun(#{upstream_client := UpstreamClientId} = RawRoute, Topic) ->
           CgId = maps:get(upstream_cg_id, RawRoute, ?NO_CG_ID_OPTION),
           validate_upstream_topics(UpstreamClientId, CgId, Topic)
       end
   , repartitioning_strategy =>
       fun(_, S) ->
           ?IS_VALID_REPARTITIONING_STRATEGY(S) orelse
             fmt("unknown repartitioning strategy ~p", [S])
       end
   , max_partitions_per_group_member =>
       fun(_, M) ->
           (is_integer(M) andalso M > 0) orelse
             fmt("max_partitions_per_group_member "
                 "should be a positive integer\nGto~p", [M])
       end
   , default_begin_offset =>
       fun(_, B) ->
           (B =:= latest orelse
            B =:= earliest orelse
            is_integer(B)) orelse
             fmt("default_begin_offset should be either "
                 "'latest', 'earliest' or an integer\nGot~p", [B])
       end
   , compression =>
       fun(_, C) ->
           C =:= no_compression orelse
           C =:= gzip           orelse
           C =:= snappy         orelse
             fmt("compression should be one of "
                 "[no_compression, gzip, snappy]\nGot~p", [C])
       end
   , required_acks =>
       fun(_, A) ->
           A =:= all    orelse
           A =:= leader orelse
           A =:= none   orelse
           A =:= -1     orelse
           A =:= 1      orelse
           A =:= 0      orelse
             fmt("required_acks should be one of "
                 "[all, leader, none, -1, 1 0]\nGot~p", [A])
       end
   , filter_module =>
       fun(_, Module) ->
           case code:ensure_loaded(Module) of
             {module, Module} ->
               true;
             {error, What} ->
               fmt("filter module ~p is not found\nreason:~p\n",
                   [Module, What])
           end
       end
   , filter_init_arg => fun(_, _Arg) -> true end
   , upstream_cg_id => fun(_, _Name) -> true end
   , offset_commit_policy => fun(_ , A) ->
                                 A =:= commit_to_kafka_v2 orelse
                                 (A =:= consumer_managed andalso undefined =/= dets:info(?OFFSETS_TAB)) orelse
                                 fmt("offset_commit_policy is set to ~p, it should be 'commit_to_kafka_v2'"
                                     "or 'consumer_managed'. ", [A])
                             end
   }.

-spec apply_route_schema(raw_route(), map(), map(), map(), [binary()]) ->
                            {ok, map()} | {error, [binary()]}.
apply_route_schema([], Schema, Defaults, Result, Errors0) ->
  Errors1 =
    case maps:to_list(maps:without(maps:keys(Defaults), Schema)) of
      [] ->
        Errors0;
      Missing ->
        MissingAttrs = [K || {K, _V} <- Missing],
        [fmt("missing mandatory attributes ~p", [MissingAttrs]) | Errors0]
    end,
  Errors = [E || E <- lists:flatten(Errors1), E =/= true],
  case [] =:= Errors of
    true ->
      %% merge (overwrite) parsed values to defaults
      {ok, maps:merge(Defaults, Result)};
    false ->
      {error, Errors}
  end;
apply_route_schema([{K, V} | Rest], Schema, Defaults, Result, Errors) ->
  case maps:find(K, Schema) of
    {ok, Fun} ->
      NewSchema = maps:remove(K, Schema),
      NewResult = Result#{K => V},
      case Fun(NewResult, V) of
        true ->
          apply_route_schema(Rest, NewSchema, Defaults, NewResult, Errors);
        Error ->
          NewErrors = [Error | Errors],
          apply_route_schema(Rest, NewSchema, Defaults, NewResult, NewErrors)
      end;
    error ->
      Error =
        case is_atom(K) of
          true  -> fmt("unknown attribute ~p", [K]);
          false -> fmt("unknown attribute ~p, expecting atom", [K])
        end,
      apply_route_schema(Rest, Schema, Defaults, Result, [Error | Errors])
  end.

%% This is to ensure there is no direct loopback due to typo for example.
%% indirect loopback would be fun for testing, so not trying to build a graph
%% {upstream, topic_1} -> {downstream, topic_2}
%% {downstream, topic_2} -> {upstream, topic_1}
%% you get a perfect data generator for load testing.
-spec ensure_no_loopback(topic_name() | [topic_name()], topic_name()) -> ok.
ensure_no_loopback(UpstreamTopics, DownstreamTopic) ->
  case lists:member(topic(DownstreamTopic), topics(UpstreamTopics)) of
    true  -> throw(direct_loopback);
    false -> ok
  end.

-spec is_configured_client_id(brod:client_id()) -> boolean().
is_configured_client_id(ClientId) ->
  brucke_config:is_configured_client_id(ClientId).

-spec validate_upstream_topics(brod:client_id(), raw_cg_id(),
                               topic_name() | [topic_name()]) -> binary().
validate_upstream_topics(_ClientId, _CgId, []) ->
  invalid_topic_name(upstream, []);
validate_upstream_topics(ClientId, CgId, Topic) when ?IS_VALID_TOPIC_NAME(Topic) ->
  validate_upstream_topic(ClientId, CgId, Topic);
validate_upstream_topics(ClientId, CgId, Topics0) when is_list(Topics0) ->
  case lists:partition(fun(T) -> ?IS_VALID_TOPIC_NAME(T) end, Topics0) of
    {Topics, []} ->
      [validate_upstream_topic(ClientId, CgId, T) || T <- Topics];
    {_, InvalidTopics} ->
      invalid_topic_name(upstream, InvalidTopics)
  end.

-spec validate_upstream_topic(brod:client_id(), raw_cg_id(), topic_name()) ->
        true | binary().
validate_upstream_topic(ClientId, RawCgId, Topic) ->
  ClusterName = brucke_config:get_cluster_name(ClientId),
  CgId = mk_cg_id(ClientId, RawCgId),
  case is_cg_duplication(ClusterName, CgId, Topic) of
    false ->
      validate_upstream_client(ClientId, Topic);
    true ->
      fmt("Duplicated routes for upstream topic ~s "
          "in the same consumer group ~s in cluster ~s.",
          [Topic, CgId, ClusterName])
  end.

%% Duplicated upstream topic is not allowed for the same client.
%% Because one `brod_consumer' allows only one subscriber.
-spec validate_upstream_client(brod:client_id(), topic_name()) ->
        true | binary().
validate_upstream_client(ClientId, Topic) ->
  case ets:lookup(?T_ROUTES, {ClientId, topic(Topic)}) of
    [] ->
      true;
    _ ->
      fmt("Upstream topic ~p is used more than once for client ~p",
          [Topic, ClientId])
  end.

%% Make upstream consumer group ID.
%% If upstream_cg_id is not found in route option,
%% build the ID from upstream cluster name (for backward compatibility).
-spec mk_cg_id(brod:client_id(), raw_cg_id()) -> cg_id().
mk_cg_id(ClientId, ?NO_CG_ID_OPTION) ->
  ClusterName = brucke_config:get_cluster_name(ClientId),
  erlang:iolist_to_binary([ClusterName, "-brucke-cg"]);
mk_cg_id(_ClientId, A) when is_atom(A) ->
  erlang:atom_to_binary(A, utf8);
mk_cg_id(_ClientId, Str) ->
  erlang:iolist_to_binary(Str).

%% @private Scan all routes (the ones already added to ETS) for duplicated
%% route. Two routes are considered duplication when they have the same upstream
%% cluster name + consumer group ID + topic name
%% @end
-spec is_cg_duplication(cluster_name(), cg_id(), topic_name()) -> boolean().
is_cg_duplication(ClusterName, CgId, Topic) ->
  lists:any(
    fun(#route{upstream = {ClientId, Topic_}, options = Options}) ->
      ClusterName_ = brucke_config:get_cluster_name(ClientId),
      CgId_ = get_cg_id(Options),
      {ClusterName_, CgId_, Topic_} =:= {ClusterName, CgId, topic(Topic)}
    end, all()).

%% @private Find the given top

-spec invalid_topic_name(upstream | downstream, any()) -> binary().
invalid_topic_name(UpOrDown_stream, NameOrList) ->
  fmt("expecting ~p topic(s) to be (a list of) atom() | string() | binary()\n"
      "got: ~p", [UpOrDown_stream, NameOrList]).

%% @private Accept atom(), string(), or binary() as topic name,
%% unified to binary().
%% @end
-spec topic(topic_name()) -> brod:topic().
topic(Topic) when is_atom(Topic)   -> topic(atom_to_list(Topic));
topic(Topic) when is_binary(Topic) -> Topic;
topic(Topic) when is_list(Topic)   -> list_to_binary(Topic).

-spec topics(topic_name() | [topic_name()]) -> [brod:topic()].
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
  ?assertNot(lists:member(?T_ROUTES, ets:all())),
  ?assertNot(lists:member(?T_DISCARDED_ROUTES, ets:all())),
  try
    init([a|b])
  catch _ : _ ->
    ?assertNot(lists:member(?T_ROUTES, ets:all())),
    ?assertNot(lists:member(?T_DISCARDED_ROUTES, ets:all()))
  end.

client_not_configured_test() ->
  clean_setup(false),
  R0 =
    [ {upstream_client, client_2}
    , {upstream_topics, topic_1}
    , {downstream_client, client_3}
    , {downstream_topic, topic_2}
    ],
  ok = init([R0]),
  ?assertEqual([], all()),
  ok = destroy().

bad_topic_name_test() ->
  clean_setup(),
  Base =
    [ {upstream_client, client_1}
    , {downstream_client, client_1}
    ],
  Route1 = [{upstream_topics, [topic_1]}, {downstream_topic, []} | Base],
  Route2 = [{upstream_topics, topic_1}, {downstream_topic, ["topic_x"]} | Base],
  Route3 = [{upstream_topics, []}, {downstream_topic, []} | Base],
  Route4 = [{upstream_topics, [[]]}, {downstream_topic, []} | Base],
  ok = init([Route1, Route2, Route3, Route4]),
  ?assertEqual([], all()),
  ok = destroy().

bad_routing_options_test() ->
  clean_setup(),
  R0 =
    [ {upstream_client, client_1}
    , {upstream_topics, topic_1}
    , {downstream_client, client_1}
    , {downstream_topic, topic_2}
    ],
  Routes = [ [{default_begin_offset, x} | R0]
           , [{repartitioning_strategy, x} | R0]
           , [{max_partitions_per_group_member, x} | R0]
           , [{"unknown_string", x} | R0]
           , [{unknown, x} | R0]
           , [{compression, x} | R0]
           , [{required_acks, 2} | R0]
           , [{required_acks, x} | R0]
           , [{filter_module, x} | R0]
           , [{offset_commit_policy, x} | R0]
           ],
  ok = init(Routes),
  ?assertEqual([], all()),
  ok = destroy().

mandatory_attribute_missing_test() ->
  clean_setup(),
  R = [ {upstream_client, client_1}
      , {upstream_topics, topic_1}
      , {downstream_client, client_1}
      ],
  ok = init([R]),
  ?assertEqual([], all()),
  ok = destroy().

duplicated_source_test() ->
  clean_setup(),
  ValidRoute1 = [ {upstream_client, client_1}
                , {upstream_topics, [<<"topic_1">>, "topic_2"]}
                , {downstream_client, client_1}
                , {downstream_topic, <<"topic_3">>}
                ],
  ValidRoute2 = [ {upstream_client, client_1}
                , {upstream_topics, <<"topic_4">>}
                , {downstream_client, client_1}
                , {downstream_topic, <<"topic_3">>}
                ],
  DupeRoute1  = [ {upstream_client, client_1}
                , {upstream_topics, "topic_1"}
                , {downstream_client, client_1}
                , {downstream_topic, topic_4}
                , {upstream_cg_id, "different-than-ValidRoute1"}
                ],
  ValidRoute3 = [ {upstream_client, client_2}
                , {upstream_topics, <<"topic_1">>}
                , {downstream_client, client_2}
                , {downstream_topic, <<"topic_5">>}
                , {upstream_cg_id, <<"the-id">>}
                ],
  ValidRoute4 = [ {upstream_client, client_3}
                , {upstream_topics, <<"topic_1">>}
                , {downstream_client, client_2}
                , {downstream_topic, <<"topic_6">>}
                , {upstream_cg_id, <<"the-id-2">>}
                ],
  DupeRoute2 = ValidRoute4,

  ok = init([ValidRoute1, ValidRoute2, DupeRoute1,
             ValidRoute3, ValidRoute4, DupeRoute2]),
  ?assertMatch([ #route{upstream = {client_1, <<"topic_1">>},
                        downstream = {client_1, <<"topic_3">>}}
               , #route{upstream = {client_1, <<"topic_2">>}}
               , #route{upstream = {client_1, <<"topic_4">>}}
               , #route{upstream = {client_2, <<"topic_1">>},
                        downstream = {client_2, <<"topic_5">>}}
               , #route{upstream = {client_3, <<"topic_1">>},
                        downstream = {client_2, <<"topic_6">>}}
               ], all_sorted()),
  ?assertEqual([], ets:lookup(?T_ROUTES, {client_1, <<"unknown_topic">>})),
  ok = destroy().

direct_loopback_test() ->
  clean_setup(),
  Routes = [ [ {upstream_client, client_1}
             , {upstream_topics, topic_1}
             , {downstream_client, client_1}
             , {downstream_topic, topic_1}
             ]
           , [ {upstream_client, client_1}
             , {upstream_topics, topic_1}
             , {downstream_client, client_2}
             , {downstream_topic, topic_2}
             ]
           ],
  ok = init(Routes),
  ?assertMatch([#route{ upstream = {client_1, <<"topic_1">>}
                      , downstream = {client_2, <<"topic_2">>}
                      , options = #{}}],
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

all_sorted() -> lists:keysort(#route.upstream, all()).

topics_test() ->
  ?assertEqual([<<"topic_1">>], topics(topic_1)).

-endif.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
