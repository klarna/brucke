-module(brucke_backlog_tests).

-include_lib("eunit/include/eunit.hrl").

full_flow_test() ->
  Funs =
    [ fun(B) -> add(0, [{pid1, ref1}], B) end
    , fun(B) -> add(1, [{pid2, ref2}, {pid2, ref3}], B) end
    , fun(B) -> ack(1, ref3, B) end
    , fun(B) -> {false, NewB} = prune(B), NewB end
    , fun(B) -> ?assertEqual([{0, [{pid1, ref1}]}, {1, [{pid2, ref2}]}], to_list(B)), B end
    , fun(B) -> ?assertEqual([pid1, pid2], get_producers(B)), B end
    , fun(B) -> ack(1, ref4, B) end
    , fun(B) -> ack(2, ref4, B) end
    , fun(B) -> ack(0, ref1, B) end
    , fun(B) -> {0, NewB} = prune(B), NewB end
    , fun(B) -> ?assertEqual([{1, [{pid2, ref2}]}], to_list(B)), B end
    , fun(B) -> ack(1, ref2, B) end
    , fun(B) -> {1, NewB} = prune(B), NewB end
    , fun(B) -> ?assertEqual([], to_list(B)) end
    ],
  ok = lists:foldl(fun(F, B) -> F(B) end, new(), Funs).

new() -> brucke_backlog:new().
add(Offset, Refs, Backlog) -> brucke_backlog:add(Offset, Refs, Backlog).
ack(Offset, Ref, Backlog) -> brucke_backlog:ack(Offset, Ref, Backlog).
prune(Backlog) -> brucke_backlog:prune(Backlog).
to_list(Backlog) -> brucke_backlog:to_list(Backlog).
get_producers(Backlog) -> brucke_backlog:get_producers(Backlog).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
