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
-module(brucke_SUITE).

%% Test framework
-export([ init_per_suite/1
        , end_per_suite/1
        , init_per_testcase/2
        , end_per_testcase/2
        , all/0
        , suite/0
        ]).

%% Test cases
-export([ t_filter/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("brod/include/brod.hrl").

-define(HOST, "localhost").
-define(HOSTS, [{?HOST, 9092}]).
-define(UPSTREAM, <<"brucke-filter-test-upstream">>).
-define(DOWNSTREAM, <<"brucke-filter-test-downstream">>).

%%%_* ct callbacks =============================================================

suite() -> [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
  ok = application:load(brucke),
  application:set_env(brucke, config_file, {priv, "brucke.yml"}),
  {ok, _} = application:ensure_all_started(brucke),
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

%% Assume brucket application is started using `priv/brucke.yml'
t_filter(Config) when is_list(Config) ->
  Client = client_1, %% configured in priv/brucke.yml
  ok = brod:start_producer(Client, ?UPSTREAM, []),
  {ok, [Offset]} = brod:get_offsets(?HOSTS, ?DOWNSTREAM, 0, latest, 1),
  ok = brod:produce_sync(Client, ?UPSTREAM, 0, <<"0">>, <<"v-0">>), %% as is
  ok = brod:produce_sync(Client, ?UPSTREAM, 0, <<"1">>, <<"v-1">>), %% ignore
  ok = brod:produce_sync(Client, ?UPSTREAM, 0, <<"2">>, <<"v-2">>), %% mutate
  Messages = fetch_loop(Offset, 10, [], 2),
  ?assertMatch([#kafka_message{key = <<"0">>, value = <<"v-0">>},
                #kafka_message{key = <<"2-X">>, value = <<"v-2-X">>}
               ], Messages).

%%%_* Help functions ===========================================================

fetch_loop(_Offset, 0, Acc, Count) -> Acc;
fetch_loop(_Offset, _Try, Acc, 0) -> Acc;
fetch_loop(Offset, N, Acc, Count) ->
  case brod:fetch(?HOSTS, ?DOWNSTREAM, 0, Offset, 1000, 10, 1000) of
    {ok, []} -> fetch_loop(Offset, N - 1, Acc, Count);
    {ok, Msgs} -> fetch_loop(Offset + length(Msgs), N - 1, Acc ++ Msgs,
                             Count - length(Msgs))
  end.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
