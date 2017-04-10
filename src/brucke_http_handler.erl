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

-define(HEADERS, [{<<"content-type">>, <<"application/json">>}]).

-export([init/3, act/2, content_types_provided/2]).

init(_, _, []) ->
	{upgrade, protocol, cowboy_rest}.

content_types_provided(Req, State) ->
	{[{<<"application/json">>, act}
	 ], Req, State}.

act(Req, State) ->
  try
    {Path, _} = cowboy_req:path(Req),
    act(Path, Req, State)
  catch
    C : E ->
      S = erlang:get_stacktrace(),
      lager:error("~p:~p\n~p", [C, E, S]),
      erlang:exit({C, E})
  end.

%% @private
act(<<"/health", _/binary>>, Req, State) ->
  {RawQS, _} = cowboy_req:qs(Req),
  QS = cow_qs:parse_qs(RawQS),
  {Status, Health} = brucke_health_check:get_report_data(QS),
  reply(Req, status_to_code(Status), jsone:encode(Health)),
	{halt, Req, State};
act(_, Req, State) ->
  reply(Req, 404, jsone:encode(#{<<"error">> => <<"Not found">>})),
	{halt, Req, State}.

%% @private
-spec reply(cowboy_req:req(), integer(), binary()) -> cowboy_req:req().
reply(Req, Code, Data) ->
  lager:info("health check reply: ~p", [Code]),
  cowboy_req:reply(Code, ?HEADERS, Data, Req).

%% @private
status_to_code(true) -> 200;
status_to_code(false) -> 500.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
