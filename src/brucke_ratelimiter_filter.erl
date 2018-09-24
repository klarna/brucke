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


%%% rate limiter for one topic
-module(brucke_ratelimiter_filter).

-behaviour(brucke_filter).

% behaviour callbacks
-export([ init/3
        , filter/7
        ]).

-export([ resetter/2
        , get_rate/1
        , set_rate/2]).

-record(cb_state, { resetter }).

-define(TAB, ?MODULE).

init(_UpstreamTopic, _UpstreamPartition = 0 , [FilterId, MsgRate]) ->
  new_tab(),
  ok = start_http(),
  Resetter = resetter_registerd_name(FilterId),
  spawn_link(?MODULE, resetter, [Resetter, MsgRate]),
  {ok, #cb_state{ resetter = Resetter }};

init(_UpstreamTopic, _UpstreamPartition, [FilterId, _MsgRate]) ->
  Resetter = resetter_registerd_name(FilterId),
  link(wait_for_resetter(Resetter)),
  {ok, #cb_state{ resetter = Resetter }}.

filter(_Topic, _Partition, _Offset, _Key, _Val, _Headers, #cb_state{resetter = Resetter} = S) ->
  maybe_block(Resetter),
  {true, S}.

resetter(Name, Rate) ->
  ets:insert(?TAB, {{setting, Name}, Rate}),
  ets:insert(?TAB, {Name, Rate}),
  register(Name, self()),
  timer:send_interval(1000, self(), reset),
  resetter_loop(Name, []).

resetter_loop(Key, PidsBlocked) ->
  receive
    reset ->
      %%% new tick, reset cnt and unblock all blocked process
      Rate = get_rate(Key),
      ets:insert(?TAB, {Key, Rate}),
      [P ! unblock || P <- PidsBlocked],
      resetter_loop(Key, []);
    {Pid, blocked} ->
      resetter_loop(Key, [Pid | PidsBlocked])
  end.

set_rate(FilterId, Rate) when is_binary(Rate) ->
  set_rate(FilterId, binary_to_integer(Rate));
set_rate(FilterId, Rate) when is_binary(FilterId) andalso is_integer(Rate) ->
  ets:insert(?TAB, {{setting, list_to_atom(binary_to_list(FilterId))}, Rate}).

get_rate(Name) when is_binary(Name) ->
  get_rate(list_to_atom(binary_to_list(Name)));
get_rate(Name) when is_atom(Name) ->
  [{_, Rate}] = ets:lookup(?TAB, {setting, Name}),
  Rate.

maybe_block(Resetter) ->
  case ets:update_counter(?TAB, Resetter, -1) of
    Cnt when Cnt < 0 ->
      Resetter ! {self(), blocked},
      receive
        unblock ->
          maybe_block(Resetter)
      end;
    _ ->
      false
  end.

new_tab()->
  ets:new(?TAB, [ named_table
                , public
                , set
                , {read_concurrency, true}
                ]).

resetter_registerd_name(Id) when is_atom(Id) ->
  Id.

wait_for_resetter(Name) ->
  case whereis(Name) of
    undefined ->
      timer:sleep(200),
      wait_for_resetter(Name);
    Pid ->
      Pid
  end.

start_http()->
  brucke_http:register_filter_handler("ratelimiter", brucke_ratelimiter_filter_http_handler, []).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
