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
-module(brucke_http).

%% API
-export([ init/0
        , register_filter_handler/3]
       ).

-define(APP, brucke).
-define(HTTP_LISTENER, http).

-define(DEF_PATHS, [ {"/ping", brucke_http_ping_handler, []}
                   , {"/", brucke_http_healthcheck_handler, []}
                   , {"/healthcheck", brucke_http_healthcheck_handler, []}
                   ]).

init() ->
  case brucke_app:http_port() of
    undefined ->
      %% not configured, do not start anything
      ok;
    Port ->
      Paths = get_route_path(),
      set_route_path(Paths),
      Dispatch = cowboy_router:compile(routes(Paths)),

      lager:info("Starting http listener on port ~p", [Port]),

      case cowboy:start_http(?HTTP_LISTENER, 8, [{port, Port}],
                                  [ {env, [{dispatch, Dispatch}]}
                                  , {onresponse, fun error_hook/4}]) of
        {ok, _Pid} ->
          ok;
        {error, {already_started, _Pid}} ->
          ok;
        Other ->
          {error, Other}
      end
  end.

error_hook(Code, _Headers, _Body, Req) ->
  {Method, _} = cowboy_req:method(Req),
  {Version, _} = cowboy_req:version(Req),
  {Path, _} = cowboy_req:path(Req),
  {{Ip, _Port}, _} = cowboy_req:peer(Req),
  Level = log_level(Code),
  lager:log(Level, self(), "~s ~s ~b ~p ~s", [Method, Path, Code, Version, inet:ntoa(Ip)]),
  Req.

log_level(Code) when Code < 400 -> info;
log_level(_Code) -> error.

-spec register_filter_handler(FilterName::string(), Handler::module(), Opts :: any()) -> ok.
register_filter_handler(FilterName, Handler, Opts) ->
  Path = {"/filter/" ++ FilterName, Handler, Opts},
  NewPaths = [ Path | get_route_path() ],
  Dispatch = cowboy_router:compile(routes(NewPaths)),
  cowboy:set_env(?HTTP_LISTENER, dispatch, Dispatch),
  ok.

-spec get_route_path() -> [cowboy_router:route_path()].
get_route_path()->
  application:get_env(?APP, route_paths, ?DEF_PATHS).

-spec set_route_path([cowboy_router:route_path()]) -> ok.
set_route_path(Paths)->
  application:set_env(?APP, route_paths, Paths).

-spec routes([cowboy_router:route_path()]) -> cowboy_router:routes().
routes(PathLists) ->
  [{'_', PathLists}].


%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
