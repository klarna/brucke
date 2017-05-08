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

%% @private
-module(brucke_http_SUITE).

%% Test framework
-export([ init_per_suite/1
        , end_per_suite/1
        , init_per_testcase/2
        , end_per_testcase/2
        , all/0
        , suite/0
        ]).

%% HTTP endpoint cases
-export([ t_ping/1
        , t_healthcheck/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(assertHttpOK(Code, Msg), (case Code >= 200 andalso Code < 300 of
                                   true  -> ok;
                                   false -> ct:fail("~p: ~s", [Code, Msg])
                                  end)).

%%%_* ct callbacks =============================================================

suite() -> [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
  _ = application:load(brucke),
  application:set_env(brucke, config_file, {priv, "brucke.yml"}),
  _ = application:ensure_all_started(brucke),
  Config.

end_per_suite(_Config) ->
  application:stop(brucke),
  application:stop(brod),
  ok.

init_per_testcase(Case, Config) ->
  try
    ?MODULE:Case({init, Config})
  catch
    error : function_clause ->
      Config
  end.

end_per_testcase(Case, Config) ->
  try
    ?MODULE:Case({'end', Config})
  catch
    error : function_clause ->
      ok
  end,
  ok.

all() -> [F || {F, _A} <- module_info(exports),
                  case atom_to_list(F) of
                    "t_" ++ _ -> true;
                    _         -> false
                  end].

%%%_* Test functions ===========================================================

t_ping(Config) when is_list(Config) ->
  URL = lists:flatten(io_lib:format("http://localhost:~p/ping", [brucke_app:http_port()])),
  {ok, {{"HTTP/1.1", ReturnCode, _State}, _Head, ReplyBody}} = httpc:request(URL),
  ?assertHttpOK(ReturnCode, ReplyBody),
  ok.

t_healthcheck(Config) when is_list(Config) ->
  URL = lists:flatten(io_lib:format("http://localhost:~p/healthcheck", [brucke_app:http_port()])),
  {ok, {{"HTTP/1.1", ReturnCode, _State}, _Head, ReplyBody}} = httpc:request(URL),
  ?assertHttpOK(ReturnCode, ReplyBody),
  ok.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
