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

%% @doc Test filter.
-module(brucke_test_filter).

-behaviour(brucke_filter).

-export([init/2, filter/5]).

init(_UpstreamTopic, _DownstreamTopic) -> ok.

filter(_Topic, _Partition, _Offset, Key, Value) ->
  case binary_to_integer(Key) rem 3 of
    0 -> true;
    1 -> false;
    2 -> {bin([Key, "-X"]), bin([Value, "-X"])}
  end.

%%%_* Private ==================================================================

bin(X) -> iolist_to_binary(X).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
