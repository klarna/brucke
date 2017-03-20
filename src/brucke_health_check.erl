%%%
%%%   Copyright (c) 2017 Klarna AB
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
-module(brucke_health_check).

-define(UPSTREAM, upstream).
-define(DOWNSTREAM, downstream).
-define(STATUS, status).
-define(MEMBERS, members).
-define(TOPIC, topic).
-define(CLIENT_ID, client_id).
-define(CLIENTS, clients).
-define(ROUTES, routes).

-include("brucke_int.hrl").

-type members_status() :: #{binary() => atom()}. %% member seqno encoded to binary
-type upstream_map() :: #{?CLIENT_ID => client(), ?TOPIC => topic_name()}.
-type downstream_map() :: #{?CLIENT_ID => client(), ?TOPIC => topic_name()}.
-type status_value() :: atom() | binary().
-type client_status() :: #{client() => status_value()}.
-type route_status() :: #{ ?UPSTREAM => upstream_map()
                         , ?DOWNSTREAM => downstream_map()
                         , ?MEMBERS => members_status()
                         , ?STATUS => status_value()
                         }.
-type status() :: #{ ?CLIENTS => [client_status()]
                   , ?ROUTES  => [route_status()]
                   }.

%% API
-export([init/0, get_report_data/1]).

init() ->
  case application:get_env(?APPLICATION, healthcheck) of
    {ok, true} ->
      Port = application:get_env(?APPLICATION, healthcheck_port, 8080),
      Dispatch = cowboy_router:compile([{'_', [{'_', brucke_http_handler, []}]}]),
      {ok, _} = cowboy:start_clear(http, 1, [{port, Port}], #{env => #{dispatch => Dispatch}}),
      ok;
    _ -> ok
  end.

-spec get_report_data(proplists:proplist()) -> {boolean(), status()}.
get_report_data(Params) ->
  AskClients = proplists:get_value(?CLIENTS, Params, true),
  {AllCliends, Status} = get_all_clients(AskClients),
  AskRoutes = proplists:get_value(?ROUTES, Params, true),
  {AllRoutes, UStatus} = get_all_routes(AskRoutes, Status),
  {UStatus, #{?CLIENTS => AllCliends, ?ROUTES => AllRoutes}}.

%% @private
-spec get_all_clients(AskedForClientStatus :: boolean()) ->
        {[route_status()], boolean()}.
get_all_clients(true) ->
  AllClients = brucke_config:all_clients(),
  lists:foldl(
    fun({ClientId, _, _}, {Acc, AccStatus}) ->
      case whereis(ClientId) of
        undefined -> {[#{ClientId => undefined} | Acc], false};
        _         -> {[#{ClientId => ok} | Acc], AccStatus}
      end
    end, {[], true}, AllClients);
get_all_clients(false) ->
  {[], true}.

%% @private
-spec get_all_routes(boolean(), boolean()) -> {[route_status()], boolean()}.
get_all_routes(true, Status) ->
  AllRoutes = brucke_config:all_routes(),
  AllRouteSups = brucke_sup:get_children(),
  DiscardedRoutes = brucke_routes:get_by_status(skipped),
  {Working, Status1} = get_working_routes(AllRoutes, AllRouteSups, Status),
  apply_discarded(Working, DiscardedRoutes, Status1);
get_all_routes(_, Status) -> {[], Status}.

%% @private
-spec get_working_routes([route()], [{upstream(), pid()}], boolean()) ->
        {[route_status()], boolean()}.
get_working_routes(AllRoutes, AllRouteSups, Status) ->
  lists:foldl(
    fun(#route{upstream = Upstream, downstream = Downstream}, {Acc, UStatus}) ->
      {Route, Status1} = check_route(Upstream, AllRouteSups, UStatus),
      {UpstreamId, UpstreamTopic} = Upstream,
      {DownstreamId, DownstreamTopic} = Downstream,
      Acc1 = [Route#{ ?UPSTREAM => #{?CLIENT_ID => UpstreamId,
                                     ?TOPIC => UpstreamTopic},
                      ?DOWNSTREAM => #{?CLIENT_ID => DownstreamId,
                                       ?TOPIC => DownstreamTopic}} | Acc],
      {Acc1, Status1}
    end, {[], Status}, AllRoutes).

%% @private Just one discarded route is enough to toggle status to false.
-spec apply_discarded([route_status()], [route()], boolean()) -> [route_status()].
apply_discarded(Working, DiscardedRoutes, Status) ->
  lists:foldl(
    fun(#route{upstream = {UpstreamClientId, UpstreamTopic},
               reason = Reason
              }, {Acc, _}) ->
      {[#{?UPSTREAM => #{?CLIENT_ID => UpstreamClientId,
                         ?TOPIC => UpstreamTopic},
          ?STATUS => Reason,
          ?MEMBERS => []} | Acc], false}
    end, {Working, Status}, DiscardedRoutes).

%% @private
-spec check_route(upstream(), [{upstream(), pid() | atom()}], boolean()) ->
        {route_status(), boolean()}.
check_route(Upstream, Routes, Status) ->
  Res = lists:keyfind(Upstream, 1, Routes),
  check_process_status(Res, Status).

%% @private
-spec check_process_status(pid(), boolean()) ->
        {route_status(), boolean()}.
check_process_status({_, RoutePid}, Status) when is_pid(RoutePid) ->
  try
    {Members, NewStatus} = get_all_brucke_members(RoutePid, Status),
    {#{?STATUS => ok, ?MEMBERS => Members}, NewStatus}
  catch exit : {noproc, _} ->
    {#{?STATUS => <<"dead">>, ?MEMBERS => []}, false}
  end;
check_process_status({_, SupStatus}, _) when is_atom(SupStatus) ->
  {#{?STATUS => SupStatus, ?MEMBERS => []}, false};
check_process_status(false, _) ->
  {#{?STATUS => <<"not under brucke_sup">>, ?MEMBERS => []}, false}.

%% @private
-spec get_all_brucke_members(pid(), boolean()) ->
        {members_status(), boolean()}.
get_all_brucke_members(RoutePid, Status) ->
  Members = brucke_sup:get_children(RoutePid),
  lists:foldl(
    fun
      ({Id, ChildStatus}, {Acc, _}) when is_atom(ChildStatus) ->  % restarting
        {Acc#{integer_to_binary(Id) => ChildStatus}, false};
      ({Id, ChildPid}, {Acc, UStatus}) when is_pid(ChildPid) ->
        {Acc#{integer_to_binary(Id) => ok}, UStatus}
    end,
    {#{}, Status}, Members).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
