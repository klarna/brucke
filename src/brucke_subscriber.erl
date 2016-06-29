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

-module(brucke_subscriber).

-export([ start_link/3
        , loop/1
        , stop/1
        ]).

-include_lib("brod/include/brod.hrl").
-include("brucke_int.hrl").

-type partition() :: kafka_partition().
-type offset() :: kafka_offset().
-type state() :: #{}.
-type pending_acks() :: #{pid() => [{reference(), offset()}]}.

-define(SUBSCRIBE_RETRY_LIMIT, 3).
-define(SUBSCRIBE_RETRY_SECONDS, 2).

%%%_* APIs =====================================================================

-spec start_link(route(), partition(), ?undef | offset()) -> {ok, pid()}.
start_link(Route, UpstreamPartition, BeginOffset) ->
  Parent = self(),
  State = #{ route              => Route
           , upstream_partition => UpstreamPartition
           , parent             => Parent
           , consumer           => subscribing
           , pending_acks       => #{}
           },
  Pid = proc_lib:spawn_link(fun() -> loop(State) end),
  Pid ! {subscribe, BeginOffset, 0},
  {ok, Pid}.

stop(Pid) when is_pid(Pid) ->
  erlang:monitor(process, Pid),
  _ = exit(Pid, shutdown),
  receive
    {'DOWN', _Ref, process, Pid, _reason} ->
      ok
  end.

%%%_* Internal Functions =======================================================

-spec loop(state()) -> no_return().
loop(State) ->
  receive
    {subscribe, BeginOffset, Count} ->
      ?MODULE:loop(subscribe(State, BeginOffset, Count));
    {Pid, #kafka_message_set{} = MsgSet} ->
      ?MODULE:loop(handle_message_set(State, Pid, MsgSet));
    #brod_produce_reply{} = Reply ->
      ?MODULE:loop(handle_produce_reply(State, Reply));
    {'DOWN', _Ref, process, Pid, _Reason} ->
      ?MODULE:loop(handle_consumer_down(State, Pid));
    Unknown ->
      erlang:exit({unknown_message, Unknown})
  end.

-spec subscribe(state(), offset(), non_neg_integer()) -> state() | no_return().
subscribe(#{ route              := Route
           , upstream_partition := UpstreamPartition
           , consumer           := subscribing
           } = State, BeginOffset, RetryCount) ->
  #route{upstream = {UpstreamClientId, UpstreamTopic}} = Route,
  SubscribeOptions =
    case is_integer(BeginOffset) of
      true ->
        true = (BeginOffset >= 0), %% assert
        [{begin_offset, BeginOffset}];
      false ->
        [] %% use the default begin offset in consumer config
    end,
  case brod:subscribe(UpstreamClientId, self(), UpstreamTopic,
                      UpstreamPartition, SubscribeOptions) of
    {ok, Pid} ->
      _ = erlang:monitor(process, Pid),
      State#{consumer := Pid};
    {error, _Reason} when RetryCount < ?SUBSCRIBE_RETRY_LIMIT ->
      Msg = {subscribe, BeginOffset, RetryCount+1},
      erlang:send_after(timer:seconds(?SUBSCRIBE_RETRY_SECONDS), self(), Msg),
      State;
    {error, Reason} ->
      exit({failed_to_subscribe, Reason})
  end;
subscribe(State, _BeginOffset, _UnknownRef) ->
  State.

-spec handle_message_set(state(), pid(), #kafka_message_set{}) -> state().
handle_message_set(#{ route        := Route
                    , pending_acks := PendingAcks
                    } = State, Pid, MsgSet) ->
  #kafka_message_set{ topic          = Topic
                    , partition      = Partition
                    , messages       = Messages
                    , high_wm_offset = _HW
                    } = MsgSet,
  #{consumer := Pid} = State, %% assert
  #route{ upstream = {_UpstreamClientId, Topic}
        , downstream = {DownstreamClientId, DownstreamTopic}
        , options = Options} = Route,
  NewPendingAcks =
    lists:map(
      fun(#kafka_message{ offset = Offset
                        , key    = Key
                        , value  = Value
                        }) ->
        DownstreamPartition = maybe_repartition(Partition, Options),
        {ok, CallRef} = brod:produce(DownstreamClientId, DownstreamTopic,
                                     DownstreamPartition,
                                     ensure_binary(Key),
                                     ensure_binary(Value)),
        {CallRef, Offset}
      end, Messages),
  State#{pending_acks := append_pending_acks(PendingAcks, NewPendingAcks)}.

ensure_binary(undefined)           -> <<>>;
ensure_binary(B) when is_binary(B) -> B.

-spec handle_produce_reply(state(), #brod_produce_reply{}) -> state().
handle_produce_reply(#{ pending_acks       := PendingAcks
                      , parent             := Parent
                      , upstream_partition := UpstreamPartition
                      , consumer           := ConsumerPid
                      , route              := Route
                      } = State, Reply) ->
  #brod_produce_reply{ call_ref = ReceivedRef
                     , result   = brod_produce_req_acked %% assert
                     } = Reply,
  case take_pending_ack(PendingAcks, ReceivedRef) of
    {ExpectedRef, Offset, Rest} when ExpectedRef =:= ReceivedRef ->
      %% tell upstream consumer to fetch more
      ok = brod:consume_ack(ConsumerPid, Offset),
      %% tell parent to update my next begin_offset in case i crash
      %% parent should also report it to coordinator and (later) commit to kafka
      Parent ! {ack, UpstreamPartition, Offset},
      State#{pending_acks := Rest};
    {ExpectedRef, Offset, _Rest} ->
      %% this means per-partition message ordering is broken
      %% must be a bug in brod or brucke if we trust kafka
      erlang:exit({unexpected_produce_reply, Route, UpstreamPartition,
                   Offset, ExpectedRef, ReceivedRef})
  end.

-spec handle_consumer_down(state(), pid()) -> state().
handle_consumer_down(#{consumer := Pid} = _State, Pid) ->
  %% maybe start a send_after retry timer
  erlang:exit(consumer_down);
handle_consumer_down(State, _UnknownPid) ->
  State.

%% @private Return a partition or a partitioner function.
maybe_repartition(UpstreamPartition, Options) ->
  case brucke_lib:get_repartitioning_strategy(Options) of
    strict_p2p ->
      UpstreamPartition;
    key_hash ->
      fun(_Topic, PartitionCount, Key, _Value) ->
        {ok, erlang:phash2(Key, PartitionCount)}
      end;
    random ->
      fun(_Topic, PartitionCount, _Key, _Value) ->
        {ok, crypto:rand_uniform(0, PartitionCount)}
      end
  end.

-spec append_pending_acks(pending_acks(), [{brod_call_ref(), offset()}]) ->
        pending_acks().
append_pending_acks(PendingAcks, []) -> PendingAcks;
append_pending_acks(PendingAcks, [{CallRef, _Offset} | _] = All) ->
  #brod_call_ref{callee = Callee} = CallRef,
  {PerCalleePendings, Rest} =
    partition_map(fun({#brod_call_ref{callee = Pid, ref = Ref}, Offset}) ->
                    Pid =:= Callee andalso {true, {Ref, Offset}}
                  end, All),
  NewPerCalleePendings = maps:get(Callee, PendingAcks, []) ++ PerCalleePendings,
  NewPendingAcks = PendingAcks#{Callee => NewPerCalleePendings},
  append_pending_acks(NewPendingAcks, Rest).

%% @private combination of lists:partition and lists:map,
%% Pred function return {true, Mapped} or false
partition_map(Pred, List) ->
  partition_map(Pred, List, [], []).

partition_map(_Pred, [], Mapped, Remain) ->
  {lists:reverse(Mapped), lists:reverse(Remain)};
partition_map(Pred, [H | T], Mapped, Remain) ->
  case Pred(H) of
    {true, R} -> partition_map(Pred, T, [R | Mapped], Remain);
    false     -> partition_map(Pred, T, Mapped, [H | Remain])
  end.

%% @private Take the first brod call reference which has the same callee
%% as given out of the list.
-spec take_pending_ack(pending_acks(), brod_call_ref()) ->
        {brod_call_ref() | none, offset() | none, pending_acks()}.
take_pending_ack(PendingAcks, #brod_call_ref{callee = Callee}) ->
  case maps:get(Callee, PendingAcks, []) of
    [] ->
      {none, none, PendingAcks};
    [{Ref, Offset} | Rest] ->
      ExpectedRef = #brod_call_ref{caller = self(), callee = Callee, ref = Ref},
      NewPendingAcks = PendingAcks#{Callee => Rest},
      {ExpectedRef, Offset, NewPendingAcks}
  end.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
