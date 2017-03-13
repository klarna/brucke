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
-module(brucke_http_handler).

-define(JSON, #{<<"content-type">> => <<"application/json">>}).

-export([init/2]).

init(Req, Opts) ->
  Req2 = act(cowboy_req:path(Req), Req),
  {ok, Req2, Opts}.


%% @private
act(<<"/health", _/binary>>, Req) ->
  QS = cowboy_req:parse_qs(Req),
  {Status, Health} = brucke_health_check:get_report_data(QS),
  reply(Req, status_to_code(Status), jsone:encode(Health));
act(_, Req) ->
  reply(Req, 404, jsone:encode(#{<<"error">> => <<"Not found">>})).

%% @private
-spec reply(cowboy_req:req(), integer(), binary()) -> cowboy_req:req().
reply(Req, Code, Data) ->
  cowboy_req:reply(Code, ?JSON, Data, Req).

%% @private
status_to_code(true) -> 100;
status_to_code(false) -> 500.