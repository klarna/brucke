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

init(UpstreamTopic, _UpstreamPartition = 0 , [MsgRate]) ->
  new_tab(),
  ok = start_http(),
  Resetter = resetter_registerd_name(UpstreamTopic),
  spawn_link(?MODULE, resetter, [UpstreamTopic, MsgRate]),
  {ok, #cb_state{ resetter = Resetter }};

init(UpstreamTopic, _UpstreamPartition, [_MsgRate]) ->
  Resetter = resetter_registerd_name(UpstreamTopic),
  link(wait_for_resetter(Resetter)),
  {ok, #cb_state{ resetter = Resetter }}.

filter(Topic, _Partition, _Offset, _Key, _Val, _Headers, #cb_state{resetter = Resetter} = S) ->
  maybe_block(Topic, Resetter),
  {true, S}.

resetter(Topic, Rate) ->
  Name = resetter_registerd_name(Topic),
  ets:insert(?TAB, {{setting,Topic}, Rate}),
  ets:insert(?TAB, {Topic, Rate}),
  register(Name, self()),
  timer:send_interval(1000, self(), reset),
  resetter_loop(Topic, []).

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

set_rate(Topic, Rate) when is_binary(Rate) ->
  set_rate(Topic, list_to_integer(binary_to_list(Rate)));
set_rate(Topic, Rate) when is_binary(Topic) andalso is_integer(Rate) ->
  ets:insert(?TAB, {{setting, Topic}, Rate}).

get_rate(Topic) ->
  [{_, Rate}] = ets:lookup(?TAB, {setting, Topic}),
  Rate.

maybe_block(Topic, Resetter) ->
  case ets:update_counter(?TAB, Topic, -1) of
    Cnt when Cnt < 0 ->
      Resetter ! {self(), blocked},
      receive
        unblock ->
          maybe_block(Topic, Resetter)
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

resetter_registerd_name(Topic) ->
  list_to_atom("ratelimiter" ++ binary_to_list(Topic)).

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
