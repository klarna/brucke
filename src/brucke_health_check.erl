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

-define(UPSTREAM, <<"upstream">>).
-define(DOWNSTREAM, <<"downstream">>).
-define(STATUS, <<"status">>).
-define(MEMBERS, <<"members">>).
-define(TOPIC, <<"topic">>).
-define(CLIENT_ID, <<"client_id">>).
-define(CLIENTS, <<"clients">>).
-define(ROUTES, <<"routes">>).

-include("brucke_int.hrl").

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

-spec get_report_data(proplists:proplist()) -> {boolean(), map()}.
get_report_data(Params) ->
  AskClients = proplists:get_value(?CLIENTS, Params, true),
  {AllCliends, Status} = get_all_clients(AskClients, true),
  AskRoutes = proplists:get_value(?ROUTES, Params, true),
  {AllRoutes, UStatus} = get_all_routes(AskRoutes, Status),
  {UStatus, #{?CLIENTS => AllCliends, ?ROUTES => AllRoutes}}.


%% @private
-spec get_all_clients(boolean(), boolean()) -> {list(map()), boolean()}.
get_all_clients(true, Status) ->
  AllClients = brucke_config:all_clients(),
  lists:foldl(
    fun({ClientId, _, _}, {Acc, AccStatus}) ->
      case whereis(ClientId) of
        undefined -> {[#{ClientId => undefined} | Acc], false};
        _ -> {[#{ClientId => ok} | Acc], AccStatus}
      end
    end, {[], Status}, AllClients);
get_all_clients(_, Status) -> {[], Status}.

%% @private
-spec get_all_routes(boolean(), boolean()) -> {list(map()), boolean()}.
get_all_routes(true, Status) ->
  AllRoutes = brucke_config:all_routes(),
  AllRouteSups = brucke_sup:get_children(),
  DiscardedRoutes = brucke_routes:get_by_status(skipped),
  {Working, Status1} = get_working_routes(AllRoutes, AllRouteSups, Status),
  apply_discarded(Working, DiscardedRoutes, Status1);
get_all_routes(_, Status) -> {[], Status}.

%% @private
get_working_routes(AllRoutes, AllRouteSups, Status) ->
  lists:foldl(
    fun(#route{upstream = Upstream, downstream = Downstream}, {Acc, UStatus}) ->
      {Route, Status1} = check_route(Upstream, AllRouteSups, UStatus),
      {UpstreamId, UpstreamTopic} = Upstream,
      {DownstreamId, DownstreamTopic} = Downstream,
      Acc1 = [Route#{?UPSTREAM => #{?CLIENT_ID => UpstreamId, ?TOPIC => UpstreamTopic},
        ?DOWNSTREAM => #{?CLIENT_ID => DownstreamId, ?TOPIC => DownstreamTopic}} | Acc],
      {Acc1, Status1}
    end, {[], Status}, AllRoutes).

%% @private
apply_discarded(Working, DiscardedRoutes, Status) ->
  lists:foldl(  % at least one discarded route is enough to toggle status to false.
    fun(#route{upstream = {Id, Topic}, reason = Reason}, {Acc, _}) ->
      {[#{?UPSTREAM => #{?CLIENT_ID => Id, ?TOPIC => Topic},
        ?STATUS => Reason, ?MEMBERS => []} | Acc], false}
    end, {Working, Status}, DiscardedRoutes).

%% @private
check_route(Upstream, Routes, Status) ->
  Res = lists:keyfind(Upstream, 1, Routes),
  check_process_status(Res, Status).

%% @private
-spec check_process_status(pid(), boolean()) -> {map(), boolean()}.
check_process_status({_, RoutePid, _, _}, Status) when is_pid(RoutePid) ->
  try
    Members = get_all_brucke_members(RoutePid, Status),
    {#{?STATUS => ok, ?MEMBERS => Members}, Status}
  catch exit : {noproc, _} ->
    {#{?STATUS => <<"dead">>, ?MEMBERS => []}, false}
  end;
check_process_status({_, Status, _, _}, _) when Status == undefined; Status == restarting ->
  {#{?STATUS => Status, ?MEMBERS => []}, false};
check_process_status(false, _) ->
  {#{?STATUS => <<"not under brucke_sup">>, ?MEMBERS => []}, false}.

%% @private
get_all_brucke_members(RoutePid, Status) ->
  Members = brucke_sup:get_children(RoutePid),
  lists:foldl(
    fun
      ({Id, ChildStatus, _, _}, {Acc, _}) when is_atom(ChildStatus) ->  % undefined/restarting
        {Acc#{integer_to_binary(Id) => ChildStatus}, false};
      ({Id, ChildPid, _, _}, {Acc, UStatus}) when is_pid(ChildPid) ->
        {Acc#{integer_to_binary(Id) => ok}, UStatus}
    end,
    {#{}, Status}, Members).