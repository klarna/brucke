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
-export([init/0]).

init() ->
  Port = brucke_app:http_port(),
  Dispatch = cowboy_router:compile([{'_',
                                     [ {"/ping", brucke_http_ping_handler, []}
                                     , {"/", brucke_http_healthcheck_handler, []}
                                     , {"/healthcheck", brucke_http_healthcheck_handler, []}
                                     ]}]),
  lager:info("Starting http listener on port ~p", [Port]),
  case cowboy:start_http(http, 8, [{port, Port}],
                                  [ {env, [{dispatch, Dispatch}]}
                                  , {onresponse, fun error_hook/4}]) of
    {ok, _Pid} ->
      ok;
    {error, {already_started, _Pid}} ->
      ok;
    _else ->
      error
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

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
