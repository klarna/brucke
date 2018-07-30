%%%
%%%   Copyright (c) 2018 Klarna Bank AB (publ)
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

%% This module manages an opaque structure for callers to:
%% add new items to backlog
%% acknowledge finished items
%% prune finished items (sucessive header items)
%% implemented as gb_tree because we need to
%% 1. lookup using key (kafka offset)
%% 2. scan items starting from smallest
-module(brucke_backlog).

-export([ new/0
        , add/3
        , ack/3
        , prune/1
        , get_producers/1
        , to_list/1
        ]).

-export_type([backlog/0]).

-opaque backlog() :: gb_trees:tree().
-type offset() :: brod:offset().
-type ref() :: {pid(), reference()}.
-define(REF_TUPLE_POS, 2).

-spec new() -> backlog().
new() -> gb_trees:empty().

%% @doc Add new pending acks for the given upstream offset to backlog.
-spec add(offset(), [ref()], backlog()) -> backlog().
add(Offset, Refs, Backlog) ->
 gb_trees:enter(Offset, Refs, Backlog).

%% @doc Delete pending reference associated to the given upstream offset.
-spec ack(offset(), reference(), backlog()) -> backlog().
ack(Offset, Ref, Backlog) ->
  case gb_trees:lookup(Offset, Backlog) of
    none -> Backlog;
    {value, Refs0} ->
      Refs = lists:keydelete(Ref, ?REF_TUPLE_POS, Refs0),
      gb_trees:enter(Offset, Refs, Backlog)
  end.

%% @doc Delete sucessive header items which are completed.
-spec prune(backlog()) -> {false | offset(), backlog()}.
prune(Backlog) ->
  prune_loop(Backlog, false).

%% @doc Get all producer pids.
-spec get_producers(backlog()) -> false | pid().
get_producers(Backlog) ->
  [Pid || Refs <- gb_trees:values(Backlog), {Pid, _Ref} <- Refs].

%% @hidden For test
-spec to_list(backlog()) -> [{offset(), [{pid(), reference()}]}].
to_list(Backlog) -> gb_trees:to_list(Backlog).

%%%_* internals ================================================================

prune_loop(Backlog, ResultOffset) ->
  case gb_trees:is_empty(Backlog) of
    true ->
      {ResultOffset, Backlog};
    false ->
      case gb_trees:take_smallest(Backlog) of
        {Offset, [], NewBacklog} ->
          %% all downstream messages from this upstream offset are finished
          prune_loop(NewBacklog, Offset);
        _ ->
          {ResultOffset, Backlog}
      end
  end.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
