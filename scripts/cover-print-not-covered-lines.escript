#!/usr/bin/env escript
%% -*- erlang -*-
%%! -smp enable -sname notcoveredlinessummary -pa _build/default/lib/brucke/ebin

%%%
%%%   Copyright (c) 2015-2018, Klarna Bank AB (publ)
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

-mode(compile).

main([_|_] = Files) ->
  ok = import_cover_data(Files),
  Modules = get_imported_modules(),
  Result = [{Mod, analyse_module(Mod)} || Mod <- Modules],
  lists:foreach(fun({Module, NotCoveredLines}) ->
                  print_mod_summary(Module, lists:sort(NotCoveredLines))
                end, Result);
main(_) ->
  io:format(user, "expecting at least one over data file", []),
  halt(1).

import_cover_data([]) -> ok;
import_cover_data([File | Rest]) ->
  io:format(user, "using coverdata file: ~s\n", [File]),
  Parent = self(),
  Ref = make_ref(),
  erlang:spawn_link(
    fun() ->
      %% shutup the chatty prints from cover:xxx calls
      {ok, F} = file:open("/dev/null", [write]),
      group_leader(F, self()),
      ok = cover:import(File),
      Parent ! {Ref, ok},
      receive
        stop ->
          %% keep it alive
          exit(normal)
      end
    end),
  receive
    {Ref, ok} ->
      import_cover_data(Rest)
  end.

get_imported_modules() ->
  All = cover:imported_modules(),
  Filtered =
    lists:filter(
      fun(Mod) ->
        case lists:reverse(atom_to_list(Mod)) of
          "ETIUS_" ++ _ -> false; %% ignore coverage for xxx_SUITE
          _             -> true
        end
      end, All),
  lists:sort(Filtered).

analyse_module(Module) ->
  {ok, Lines} = cover:analyse(Module, coverage, line),
  lists:foldr(
    fun({{_Mod, 0}, _}, Acc)          -> Acc;
       ({{_Mod, _Line}, {1, 0}}, Acc) -> Acc;
       ({{_Mod, Line}, {0, 1}}, Acc)  -> [Line | Acc]
    end, [], Lines).

print_mod_summary(_Module, []) -> ok;
print_mod_summary(Module, NotCoveredLines) ->
  io:format(user, "================ ~p ================\n", [Module]),
  case whicherl(Module) of
    Filename when is_list(Filename) ->
      print_lines(Filename, NotCoveredLines);
    _ ->
      erlang:error({erl_file_not_found, Module})
  end.

print_lines(_Filename, []) ->
  ok;
print_lines(Filename, Lines) ->
  {ok, Fd} = file:open(Filename, [read]),
  try
    print_lines(Fd, 1, Lines)
  after
    file:close(Fd)
  end.

print_lines(_Fd, _N, []) ->
  ok;
print_lines(Fd, N, [M | Rest] = Lines) ->
  Continue =
    case io:get_line(Fd, "") of
      eof ->
        erlang:error({eof, N, Lines});
      Line when N =:= M ->
        io:format(user, "~5p: ~s", [N, Line]),
        Rest;
     _ ->
       Lines
    end,
  print_lines(Fd, N+1, Continue).

whicherl(Module) when is_atom(Module) ->
  {ok, {Module, [{compile_info, Props}]}} =
    beam_lib:chunks(code:which(Module), [compile_info]),
  proplists:get_value(source, Props).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
