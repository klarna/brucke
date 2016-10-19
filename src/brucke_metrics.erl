%%%
%%%   Copyright (c) 2016 Klarna AB
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
-module(brucke_metrics).

-export([ init/0
        , inc/2
        , set/2
        , format_topic/1
        ]).

-compile({no_auto_import,[set/1]}).

-define(WRITER, ?MODULE). %% the registered name of graphiter_writer

%% @doc Initialize metrics writer.
-spec init() -> ok | {error, any()}.
init() ->
  Prefix0 = atom_to_list(?APPLICATION),
  Prefix = case application:get_env(?APPLICATION, graphite_root_path) of
             {ok, Root} -> Root;
             undefined  -> Prefix0
           end,
  case application:get_env(?APPLICATION, graphite_host) of
    undefined ->
      %% not configured, do not start anything
      ok;
    {ok, Host} ->
      Opts0 = [{prefix, iolist_to_binary(Prefix)}, {host, Host}],
      Opts = case application:get_env(?APPLICATION, graphite_port) of
               {ok, Port} -> [{port, Port} | Opts0];
               undefined  -> Opts0
             end,
      {ok, _Pid} = graphiter:start(?WRITER, Opts),
      ok
  end.

%% @doc Increment counter.
-spec inc(graphiter:path(), integer()) -> ok.
inc(_Path, 0) -> ok;
inc(Path, Inc) when is_integer(Inc) ->
  graphiter:incr_cast(?WRITER, Path, Inc).

%% @doc Set gauge value.
-spec set(graphiter:path(), number()) -> ok.
set(Path, Val) when is_number(Val) ->
  graphiter:cast(?WRITER, Path, Val).

%% @doc Replace the dots in topic names with hyphens.
-spec format_topic(brod:topic()) -> binary().
format_topic(Topic) ->
  binary:replace(Topic, <<".">>, <<"-">>).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
