%%%
%%%   Copyright (c) 2016-2017 Klarna AB
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
-define(UNACKED(CallRef, Offset), {CallRef, Offset, unacked}).
-define(ACKED(CallRef, Offset), {CallRef, Offset, acked}).
-type pending_acks() :: [{brod_call_ref() | ignored, offset(), unacked | acked}].
-type cb_state() :: brucke_filter:cb_state().

-define(SUBSCRIBE_RETRY_LIMIT, 3).
-define(SUBSCRIBE_RETRY_SECONDS, 2).

%% Because the upstream messages might be dispatched to
%% different downstream partitions, there is no single downstream
%% producer process to monitor.
%% Instead, we periodically send a loop-back message to check if
%% the producer pids are still alive
-define(CHECK_PRODUCER_DELAY, 30000).
-define(CHECK_PRODUCER_MSG, check_producer).

%%%_* APIs =====================================================================

-spec start_link(route(), partition(), ?undef | offset()) -> {ok, pid()}.
start_link(Route, UpstreamPartition, BeginOffset) ->
  Parent = self(),
  #route{ upstream = {UpstreamClientId, UpstreamTopic}
        , options = Options
        } = Route,
  #{ filter_module := FilterModule
   , filter_init_arg := InitArg
   } = Options,
  {ok, CbState} = brucke_filter:init(FilterModule, UpstreamTopic,
                                     UpstreamPartition, InitArg),
  UpstreamClusterName = brucke_config:get_cluster_name(UpstreamClientId),
  State = #{ route              => Route
           , upstream_partition => UpstreamPartition
           , parent             => Parent
           , consumer           => subscribing
           , pending_acks       => []
           , upstream_cluster   => UpstreamClusterName
           , filter_cb_state    => CbState
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

%% @private
-spec loop(state()) -> no_return().
loop(State) ->
  _ = erlang:send_after(?CHECK_PRODUCER_DELAY, self(), ?CHECK_PRODUCER_MSG),
  receive
    Msg ->
      ?MODULE:loop(handle_msg(State, Msg))
  end.

%% @private
-spec handle_msg(state(), term()) -> state() | no_return().
handle_msg(State, {subscribe, BeginOffset, Count}) ->
  subscribe(State, BeginOffset, Count);
handle_msg(State, ?CHECK_PRODUCER_MSG) ->
  check_producer(State);
handle_msg(State, {Pid, #kafka_message_set{} = MsgSet}) ->
  handle_message_set(State, Pid, MsgSet);
handle_msg(State, #brod_produce_reply{} = Reply) ->
  handle_produce_reply(State, Reply);
handle_msg(State, {'DOWN', _Ref, process, Pid, _Reason}) ->
  handle_consumer_down(State, Pid);
handle_msg(_State, Unknown) ->
  erlang:exit({unknown_message, Unknown}).

%% @private
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
      _ = erlang:send_after(timer:seconds(?SUBSCRIBE_RETRY_SECONDS), self(), Msg),
      State;
    {error, Reason} ->
      exit({failed_to_subscribe, Reason})
  end;
subscribe(State, _BeginOffset, _UnknownRef) ->
  State.

%% @private
-spec handle_message_set(state(), pid(), #kafka_message_set{}) -> state().
handle_message_set(#{ route              := Route
                    , upstream_cluster   := Cluster
                    , upstream_partition := Partition
                    } = State, Pid, MsgSet) ->
  #route{ upstream = {_UpstreamClientId, Topic}
        , options  = RouteOptions
        } = Route,
  #{consumer := Pid} = State, %% assert
  #kafka_message_set{high_wm_offset = HighWmOffset} = MsgSet,
  ?MX_HIGH_WM_OFFSET(Cluster, Topic, Partition, HighWmOffset),
  ?MX_TOTAL_VOLUME(Cluster, Topic, Partition, msg_set_bytes(MsgSet)),
  NewState = State#{high_wm_offset => HighWmOffset},
  do_handle_message_set(NewState, MsgSet, RouteOptions).

%% @private
do_handle_message_set(#{ route := Route
                       , pending_acks := PendingAcks
                       , filter_cb_state := CbState
                       } = State, MsgSet, RouteOptions) ->
  RepartStrategy = brucke_lib:get_repartitioning_strategy(RouteOptions),
  #{filter_module := FilterModule} = RouteOptions,
  #kafka_message_set{ topic     = Topic
                    , partition = Partition
                    , messages  = Messages
                    } = MsgSet,
  #route{ upstream = {_UpstreamClientId, Topic}
        , downstream = {DownstreamClientId, DownstreamTopic}
        } = Route,
  PartitionOrFun = maybe_repartition(Partition, RepartStrategy),
  FilterFun =
    fun(Offset, Key, Value, CbStateIn) ->
        brucke_filter:filter(FilterModule, Topic, Partition, Offset,
                             Key, Value, CbStateIn)
    end,
  ProduceFun =
    fun(Key, Value) ->
        {ok, CallRef} = brod:produce(DownstreamClientId,
                                     DownstreamTopic,
                                     PartitionOrFun,
                                     Key, Value),
        CallRef
    end,
  {NewPendingAcks, NewCbState} =
    produce(FilterFun, ProduceFun, Messages, [], CbState),
  handle_acked(State#{ pending_acks := PendingAcks ++ NewPendingAcks
                     , filter_cb_state := NewCbState
                     }).

%% @private
-spec produce(fun((offset(), kafka_key(), kafka_value(), cb_state()) ->
                    brucke_filter:filter_return()),
              fun((kafka_key(), kafka_value()) -> brod_call_ref()),
              [#kafka_message{}], pending_acks(),
              cb_state()) -> {pending_acks(), cb_state()}.
produce(_FilterFun, _ProduceFun, [], PendingAcks, CbState) ->
  {lists:reverse(PendingAcks), CbState};
produce(FilterFun, ProduceFun,
        [#kafka_message{offset = Offset,
                        key = Key,
                        value = Value} | Rest],
        PendingAcks0, CbState0) ->
  {FilterResult, CbState} = FilterFun(Offset, Key, Value, CbState0),
  NewPending =
    case FilterResult of
      true ->
        ?UNACKED(ProduceFun(Key, Value), Offset);
      {NewKey, NewValue} ->
        ?UNACKED(ProduceFun(NewKey, NewValue), Offset);
      false ->
        ?ACKED(ignored, Offset)
    end,
  PendingAcks = [NewPending | PendingAcks0],
  produce(FilterFun, ProduceFun, Rest, PendingAcks, CbState).

%% @private
-spec handle_produce_reply(state(), #brod_produce_reply{}) -> state().
handle_produce_reply(#{ pending_acks       := PendingAcks
                      , upstream_partition := UpstreamPartition
                      , route              := Route
                      } = State, Reply) ->
  #brod_produce_reply{ call_ref = CallRef
                     , result   = brod_produce_req_acked %% assert
                     } = Reply,
  Offset =
    case lists:keyfind(CallRef, 1, PendingAcks) of
      ?UNACKED(CallRef, Offset_) ->
        Offset_;
      _ ->
        erlang:exit({unexpected_produce_reply, Route, UpstreamPartition,
                     PendingAcks, CallRef})
    end,
  NewPendingAcks =
    lists:keyreplace(CallRef, 1, PendingAcks, ?ACKED(CallRef, Offset)),
  handle_acked(State#{pending_acks := NewPendingAcks}).

%% @private
-spec handle_acked(state()) -> state().
handle_acked(#{ pending_acks       := PendingAcks
              , parent             := Parent
              , upstream_cluster   := UpstreamCluster
              , upstream_partition := UpstreamPartition
              , consumer           := ConsumerPid
              , route              := Route
              , high_wm_offset     := HighWmOffset
              } = State) ->
  #route{upstream = {_UpstreamClientId, UpstreamTopic}} = Route,
  {OffsetToAck, NewPendingAcks} = remove_acked_header(PendingAcks, false),
  case is_integer(OffsetToAck) of
    true ->
      %% tell upstream consumer to fetch more
      ok = brod:consume_ack(ConsumerPid, OffsetToAck),
      ?MX_CURRENT_OFFSET(UpstreamCluster, UpstreamTopic,
                         UpstreamPartition, OffsetToAck),
      ?MX_LAGGING_OFFSET(UpstreamCluster, UpstreamTopic,
                         UpstreamPartition, HighWmOffset - OffsetToAck),
      %% tell parent to update my next begin_offset in case i crash
      %% parent should also report it to coordinator and (later) commit to kafka
      Parent ! {ack, UpstreamPartition, OffsetToAck};
    false ->
      ok
  end,
  State#{pending_acks := NewPendingAcks}.

%% @private
-spec remove_acked_header(pending_acks(), false | offset()) ->
        {false | offset(), pending_acks()}.
remove_acked_header([], LastOffset) ->
  {LastOffset, []};
remove_acked_header([?UNACKED(_CallRef, _Offset) | _] = Pending, LastOffset) ->
  {LastOffset, Pending};
remove_acked_header([?ACKED(_CallRef, Offset) | Rest], _LastOffset) ->
  remove_acked_header(Rest, Offset).

%% @private Return 'true' if ALL producers of unacked requests are still alive.
-spec check_producer(state()) -> state() | no_return().
check_producer(#{pending_acks := Pendings} = State) ->
  Pred = fun(?UNACKED(#brod_call_ref{callee = ProducerPid}, _Offset)) ->
             erlang:is_process_alive(ProducerPid);
            (_) ->
             true
         end,
  NewState =
    case lists:all(Pred, Pendings) of
      true  -> State;
      false -> erlang:exit(producer_down)
    end,
  _ = erlang:send_after(?CHECK_PRODUCER_DELAY, self(), ?CHECK_PRODUCER_MSG),
  NewState.

%% @private
-spec handle_consumer_down(state(), pid()) -> state().
handle_consumer_down(#{consumer := Pid} = _State, Pid) ->
  %% maybe start a send_after retry timer
  erlang:exit(consumer_down);
handle_consumer_down(State, _UnknownPid) ->
  State.

%% @private Return a partition or a partitioner function.
-spec maybe_repartition(partition(), repartitioning_strategy()) ->
        partition() | brod_partition_fun().
maybe_repartition(Partition, strict_p2p) ->
  Partition;
maybe_repartition(_Partition, key_hash) ->
  fun(_Topic, PartitionCount, Key, _Value) ->
    {ok, erlang:phash2(Key, PartitionCount)}
  end;
maybe_repartition(_Partition, random) ->
  fun(_Topic, PartitionCount, _Key, _Value) ->
    {ok, crypto:rand_uniform(0, PartitionCount)}
  end.

%% @private
msg_set_bytes(#kafka_message_set{messages = Messages}) ->
  msg_set_bytes(Messages, 0).

%% @private
msg_set_bytes([], Bytes) -> Bytes;
msg_set_bytes([#kafka_message{key = K, value = V} | Rest], Bytes) ->
  msg_set_bytes(Rest, Bytes + msg_bytes(K) + msg_bytes(V)).

%% @private
msg_bytes(undefined)           -> 0;
msg_bytes(B) when is_binary(B) -> erlang:size(B).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
