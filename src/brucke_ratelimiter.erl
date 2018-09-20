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
-module(brucke_ratelimiter).

-behaviour(gen_server).

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        , format_status/2]).

%% called by brucke_sup
-export([init/0]).

-export([ ensure_started/2
        , name_it/1
        , set_rate/2
        , get_rate/1
        , acquire/1]).

-include("brucke_int.hrl").

-define(TAB, ?RATELIMITER_TAB).

-record(state, { id
               , ticker
               , interval
               , threshold
               , blocked_pids = []
               }).

-type rate() :: {Interval :: non_neg_integer(), Threshold :: non_neg_integer()}.
-type rid() :: atom() | {Cluster :: list() | binary() | atom(),
                         CgId :: list() | binary() | atom() }.
%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link(Name::atom(), Rate :: any())
                -> {ok, Pid :: pid()} |
                   {error, Error :: {already_started, pid()}} |
                   {error, Error :: term()} |
                   ignore.
start_link(Name, Rate) ->
  gen_server:start_link({local, Name}, ?MODULE, [Name, Rate], []).

-spec ensure_started(Name :: atom(), Rate :: rate()) -> ok.
ensure_started(Name, {Interval, Threshold}) ->
  case brucke_ratelimiter:start_link(Name, {Interval, Threshold}) of
    {ok, _RPid} ->
      ok;
    {error, {already_started, _RPid}} ->
      ok
  end.

-spec name_it([string() | binary() | atom()]) -> atom().
name_it(Names)->
  NamesStr = lists:map(fun to_list/1, Names),
  list_to_atom(string:join(["rtl" | NamesStr ], "_")).

-spec set_rate(Rid :: rid(), RateSettings :: proplist:proplist()) -> ok | noargs.
set_rate({Cluster, Cgid}, RateSettings) ->
  set_rate(name_it([Cluster, Cgid]), RateSettings);
set_rate(Rid, RateSettings) when is_list(RateSettings)->
  gen_server:call(Rid, {set_rate, RateSettings}).

-spec get_rate(rid()) -> rate().
get_rate({Cluster, Cgid}) ->
  get_rate(name_it([Cluster, Cgid]));
get_rate(Rid) when is_atom(Rid)->
  gen_server:call(Rid, get_rate).

%% acquire blocks if necessary until new window.
-spec acquire(RateLimiter :: atom()) -> ok.
acquire(Server)->
  case ets:update_counter(?TAB, Server, {2, -1, 0, 0}) of
    0 ->
      unblock = gen_server:call(Server, blocked, infinity),
      acquire(Server);
    _  ->
      ok
  end.

init() ->
  init_http(),
  init_tab().


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: list())
          -> {ok, State :: term()} |
             {ok, State :: term(), Timeout :: timeout()} |
             {ok, State :: term(), hibernate} |
             {stop, Reason :: term()} |
             ignore.
init([Id, {Interval, Threshold}]) ->
  process_flag(trap_exit, true),
  %% init counter
  reset_counter(Id, Threshold),
  {ok, Tref} = timer:send_interval(Interval, self(), reset),
  {ok, #state{id = Id, ticker = Tref, interval = Interval, threshold = Threshold}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
                     {reply, Reply :: term(), NewState :: term()} |
                     {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
                     {reply, Reply :: term(), NewState :: term(), hibernate} |
                     {noreply, NewState :: term()} |
                     {noreply, NewState :: term(), Timeout :: timeout()} |
                     {noreply, NewState :: term(), hibernate} |
                     {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
                     {stop, Reason :: term(), NewState :: term()}.
handle_call(blocked, From, #state{blocked_pids = BlockedPids} = State) ->
  {noreply, State#state{blocked_pids = [From | BlockedPids]}};


handle_call(get_rate, _From, #state{interval = Interval, threshold = Threshold} = State) ->
  {reply, {Interval, Threshold}, State};

handle_call({set_rate, Rateprop}, _From, #state{ ticker = OldTref
                                               , id = Rid
                                               , interval = OldInterval
                                               , threshold = OldThreshold} = State) ->
  NewInterval  = proplists:get_value(interval, Rateprop, undefined),
  NewThreshold = proplists:get_value(threshold, Rateprop, undefined),

  %%% fine control what to reset to reduce unnecessary jitter
  case {NewInterval, NewThreshold} of
    {undefined, undefined} ->
      {reply, noargs, State};
    {undefined, OldThreshold} ->
      {reply, ok, State};
    {undefined, _} when is_integer(NewThreshold) ->
      reset_counter(Rid, NewThreshold),
      {reply, ok, State#state{threshold = NewThreshold}};
    {OldInterval, OldThreshold} ->
      {reply, ok, State};
    {OldInterval, _} when is_integer(NewThreshold) ->
      reset_counter(Rid, NewThreshold),
      {reply, ok, State#state{threshold = NewThreshold}};
    {NewInterval, _} ->
      %% interval is updated, reset ticker
      NewTref = reset_ticker(OldTref, NewInterval),
      reset_counter(Rid, NewThreshold),
      {reply, ok, State#state{ticker = NewTref, interval = NewInterval, threshold = NewThreshold}}
  end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
                     {noreply, NewState :: term()} |
                     {noreply, NewState :: term(), Timeout :: timeout()} |
                     {noreply, NewState :: term(), hibernate} |
                     {stop, Reason :: term(), NewState :: term()}.
handle_cast(_, #state{} = State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
                     {noreply, NewState :: term()} |
                     {noreply, NewState :: term(), Timeout :: timeout()} |
                     {noreply, NewState :: term(), hibernate} |
                     {stop, Reason :: normal | term(), NewState :: term()}.
handle_info(reset, #state{id = Rid, blocked_pids = Pids,
                          threshold = Threshold} = State) ->
  %%% new tick, reset cnt and unblock all blocked process
  reset_counter(Rid, Threshold),
  [gen_server:reply(P, unblock) ||  P <- Pids],
  {noreply, State#state{blocked_pids = []}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: term(),
                  Extra :: term()) -> {ok, NewState :: term()} |
                                      {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
                    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
  Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
init_http() ->
  brucke_http:register_plugin_handler("ratelimiter/:cluster/:cgid",
                                     brucke_ratelimiter_http_handler, []).
init_tab()->
  ets:new(?TAB, [ named_table
                , public
                , set
                , {read_concurrency, true}
                ]),
  ok.

reset_ticker(OldTref, NewInterval) ->
  timer:cancel(OldTref),
  {ok, Tref} = timer:send_interval(NewInterval, self(), reset),
  Tref.

reset_counter(Id, NewCnt) ->
  ets:insert(?TAB, {Id, NewCnt}).

to_list(N) when is_list(N) -> N;
to_list(N) when is_binary(N) -> binary_to_list(N);
to_list(N) when is_atom(N) -> atom_to_list(N).


%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
