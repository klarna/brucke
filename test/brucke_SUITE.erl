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
-export([ t_basic/1
        , t_filter/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("brod/include/brod.hrl").

-define(HOST, "localhost").
-define(HOSTS, [{?HOST, 9092}]).

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

t_basic(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-basic-test-upstream">>,
  DOWNSTREAM = <<"brucke-basic-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, [Offset]} = brod:get_offsets(?HOSTS, DOWNSTREAM, 0, latest, 1),
  V0 = uniq_int(),
  V1 = uniq_int(),
  V2 = uniq_int(),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"0">>, bin(V0)),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"1">>, bin(V1)),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"2">>, bin(V2)),
  FetchFun = fun(Of) ->
                 brod:fetch(?HOSTS, DOWNSTREAM, 0, Of, 1000, 10, 1000)
             end,
  Messages = fetch_loop(FetchFun, V0, Offset, _TryMax = 20, [], _Count = 3),
  ?assertEqual([{0, V0}, {1, V1}, {2, V2}], Messages).

%% Send 3 messages to upstream topic
%% Expect them to be mirrored to downstream toicp with below filtering logic
%% When the key integer's mod-3 is a remainder
%% 0: message is forwarded as-is to downstream
%% 1: message is discarded
%% 2: value integer is transformed with '+ 1' then forwarded to downstream.
%%
%% Assume brucket application is started using `priv/brucke.yml'
t_filter(Config) when is_list(Config) ->
  UPSTREAM = <<"brucke-filter-test-upstream">>,
  DOWNSTREAM = <<"brucke-filter-test-downstream">>,
  Client = client_1, %% configured in priv/brucke.yml
  ok = brod:start_producer(Client, UPSTREAM, []),
  {ok, [Offset]} = brod:get_offsets(?HOSTS, DOWNSTREAM, 0, latest, 1),
  V0 = uniq_int(),
  V1 = uniq_int(),
  V2 = uniq_int(),
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"0">>, bin(V0)), %% as is
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"1">>, bin(V1)), %% ignore
  ok = brod:produce_sync(Client, UPSTREAM, 0, <<"2">>, bin(V2)), %% mutate
  FetchFun = fun(Of) ->
                 brod:fetch(?HOSTS, DOWNSTREAM, 0, Of, 1000, 10, 1000)
             end,
  Messages = fetch_loop(FetchFun, V0, Offset, _TryMax = 20, [], 2),
  ?assertEqual([{0, V0}, %% as is
                %% 1 is discarded
                {2, V2 + 1} %% transformed
               ], Messages).

%%%_* Help functions ===========================================================

fetch_loop(_F, _V0, _Offset, N, Acc, C) when N =< 0 orelse C =< 0 -> Acc;
fetch_loop(F, V0, Offset, N, Acc, Count) ->
  case F(Offset) of
    {ok, []} ->
      fetch_loop(F, V0, Offset, N - 1, Acc, Count);
    {ok, Msgs0} ->
      Msgs =
        lists:filtermap(fun(#kafka_message{key = Key, value = Value}) ->
                            case int(Value) >= V0 of
                              true  -> {true, {int(Key), int(Value)}};
                              false -> false
                            end
                        end, Msgs0),
      ct:pal("received: ~p", [Msgs]),
      C = length(Msgs),
      fetch_loop(F, V0, Offset + C, N - 1, Acc ++ Msgs, Count - C)
  end.

uniq_int() ->
  {M, S, Micro} = os:timestamp(),
  (M * 1000000 + S) * 1000000 + Micro.

bin(X) -> integer_to_binary(X).
int(B) -> binary_to_integer(B).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
