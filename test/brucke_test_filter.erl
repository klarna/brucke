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
-module(brucke_test_filter).

-export([ init/3
        , filter/6
        ]).

-behaviour(brucke_filter).

-record(state, {seqno = 0}).

init(_UpstreamTopic, _DownstreamTopic, _InitArg) ->
  {ok, #state{}}.

filter(_Topic, _Partition, _Offset, Key, Value, #state{} = State) ->
  Seqno = State#state.seqno,
  Res =
    case Seqno rem 3 of
      0 -> true; %% as is
      1 -> false; %% discard
      2 -> {Key, bin(int(Value) + 1)} %% transform
    end,
  {Res, State#state{seqno = Seqno + 1}}.

bin(X) -> integer_to_binary(X).
int(B) -> binary_to_integer(B).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
