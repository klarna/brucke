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
-module(brucke_ratelimiter_filter_http_handler).

-export([ init/3
        , allowed_methods/2
        , content_types_accepted/2
        , handle_request/2
        , content_types_provided/2
        ]).

-include("brucke_int.hrl").

init(_Transport, _Req, []) ->
  {upgrade, protocol, cowboy_rest}.

allowed_methods(Req, State) ->
  {[<< "POST" >>, << "PUT" >>], Req, State}.

content_types_accepted(Req, State) ->
  {[{{<<"application">>, <<"json">>, []}, handle_request}], Req, State}.

content_types_provided(Req, State) ->
  {[{{<<"application">>, <<"json">>, []}, handle_request}], Req, State}.

handle_request(Req, State) ->
  {ok, Body, _Req2} = cowboy_req:body(Req),
  Rates = jsone:decode(Body,  [{object_format, proplist}]),
  Res = [brucke_ratelimiter_filter:set_rate(K, V) || {K, V} <- Rates],
  {true, cowboy_req:set_resp_body(jsone:encode(Res), Req), State}.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
