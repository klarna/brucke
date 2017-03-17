%%%
%%%   Copyright (c) 2016-2017 Klarna AB
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

-module(brucke_sup).
-behaviour(supervisor3).

-export([ start_link/0
        , init/1
        , post_init/1
        , get_children/0
        , get_children/1
        ]).

-include("brucke_int.hrl").

-define(ROOT_SUP, brucke_sup).
-define(GROUP_MEMBER_SUP, brucke_member_sup).

start_link() ->
  supervisor3:start_link({local, ?ROOT_SUP}, ?MODULE, ?ROOT_SUP).

-spec get_children() -> [{ID::term(), pid() | atom()}].
get_children() ->
  get_children(?ROOT_SUP).

-spec get_children(atom() | pid()) -> [{ID::term(), pid() | atom()}].
get_children(Pid) ->
  lists:map(fun({ID, ChildPid, _Worker, _Modules}) ->
                {ID, ChildPid}
            end, supervisor3:which_children(Pid)).

init(?ROOT_SUP) ->
  ok = brucke_config:init(),
  ok = brucke_metrics:init(),
  AllClients = brucke_config:all_clients(),
  lists:foreach(
    fun({ClientId, Endpoints, ClientConfig}) ->
      ok = brod:start_client(Endpoints, ClientId, ClientConfig)
    end, AllClients),
  AllRoutes = brucke_config:all_routes(),
  RouteSups = [route_sup_spec(Route) || Route <- AllRoutes],
  {ok, {{one_for_one, 0, 1}, RouteSups}};
init({?GROUP_MEMBER_SUP, _Route}) ->
  post_init.

post_init({?GROUP_MEMBER_SUP, #route{} = Route}) ->
  #route{ upstream = Upstream
        , downstream = Downstream
        , options = Options} = Route,
  case {get_partition_count(Upstream), get_partition_count(Downstream)} of
    {none, _} ->
      Msg = "upstream topic not found in kafka",
      ok = brucke_lib:log_skipped_route_alert(Route, Msg),
      exit(normal);
    {_, none} ->
      Msg = "downstream topic not found in kafka",
      ok = brucke_lib:log_skipped_route_alert(Route, Msg),
      exit(normal);
    {UpstreamPartitionsCount, DownstreamPartitionCount} ->
      case validate_repartitioning_strategy(UpstreamPartitionsCount,
                                            DownstreamPartitionCount,
                                            Options) of
        ok ->
          Workers = route_worker_specs(Route, UpstreamPartitionsCount),
          {ok, {{one_for_one, 0, 1}, Workers}};
        {error, Msg} ->
          ok = brucke_lib:log_skipped_route_alert(Route, Msg),
          exit(normal)
      end
  end.

route_sup_spec(#route{upstream = Upstream} = Route) ->
  { _ID       = Upstream
  , _Start    = {supervisor3, start_link, [?MODULE, {?GROUP_MEMBER_SUP, Route}]}
  , _Restart  = {transient, _DelaySeconds = 20}
  , _Shutdown = infinity
  , _Type     = supervisor
  , _Module   = [?MODULE]
  }.

route_worker_specs(#route{options = Options} = Route, PartitionsCount) ->
  PartitionCountLimit = max_partitions_per_group_member(Options),
  route_worker_specs(Route, PartitionCountLimit, _Seqno = 1, PartitionsCount).

route_worker_specs(    _,     _,     _, Count) when Count =< 0 -> [];
route_worker_specs(Route, Limit, Seqno, Count) ->
  [{ _ID       = Seqno
   , _Start    = {brucke_member, start_link, [Route]}
   , _Restart  = {permanent, _DelaySeconds = 60}
   , _Shutdown = 5000
   , _Type     = worker
   , _Module   = [brucke_member]
   } | route_worker_specs(Route, Limit, Seqno+1, Count - Limit)].

get_partition_count({ClientId, Topic}) ->
  case brod_client:get_partitions_count(ClientId, Topic) of
    {ok, Count} ->
      Count;
    {error, 'UnknownTopicOrPartition'} ->
      none;
    {error, Reason} ->
      exit({failed_to_get_partiton_count, ClientId, Topic, Reason})
  end.

-spec max_partitions_per_group_member(route_options()) -> pos_integer().
max_partitions_per_group_member(Options) ->
  maps:get(max_partitions_per_group_member, Options,
           ?MAX_PARTITIONS_PER_GROUP_MEMBER).

-spec validate_repartitioning_strategy(pos_integer(), pos_integer(),
                                       route_options()) ->
            ok | {error, iodata()}.
validate_repartitioning_strategy(UpstreamPartitionCount,
                                 DownstreamPartitionCount, Options) ->
  case brucke_lib:get_repartitioning_strategy(Options) of
    strict_p2p when UpstreamPartitionCount =/= DownstreamPartitionCount ->
      {error, "The number of partitions in upstream/downstream topics should "
              "be the same for 'strict_p2p' repartitioning strategy"};
    _Other ->
      ok
  end.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
