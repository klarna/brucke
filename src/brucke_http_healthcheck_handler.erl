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
-module(brucke_http_healthcheck_handler).

-export([ init/2
        , init/3
        , handle_request/2
        , content_types_provided/2
        ]).


-include("brucke_int.hrl").

init(Req, Opts) ->
  {cowboy_rest, Req, Opts}.

init(_Transport, _Req, []) ->
  {upgrade, protocol, cowboy_rest}.

content_types_provided(Req, State) ->
  {[{<<"application/json">>, handle_request}], Req, State}.

handle_request(Req, State) ->
  HealthStatus0 = brucke_routes:health_status(),
  Status = get_status_string(HealthStatus0),
  HealthStatus = maps:put(status, Status, HealthStatus0),
  {jsone:encode(HealthStatus), Req, State}.

%% @private
get_status_string(#{unhealthy := [], discarded := []}) -> <<"ok">>;
get_status_string(_HealthStatus) -> <<"failing">>.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
