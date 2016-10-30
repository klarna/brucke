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
-define(UNACKED(CallRef, Offset), {CallRef, Offset, unacked}).
-define(ACKED(CallRef, Offset) ,{CallRef, Offset, acked}).
-type pending_acks() :: [{brod_call_ref(), offset(), unacked | acked}].

-define(SUBSCRIBE_RETRY_LIMIT, 3).
-define(SUBSCRIBE_RETRY_SECONDS, 2).

%%%_* APIs =====================================================================

-spec start_link(route(), partition(), ?undef | offset()) -> {ok, pid()}.
start_link(Route, UpstreamPartition, BeginOffset) ->
  Parent = self(),
  #route{upstream = {UpstreamClientId, _UpstreamTopic}} = Route,
  UpstreamClusterName = brucke_config:get_cluster_name(UpstreamClientId),
  State = #{ route              => Route
           , upstream_partition => UpstreamPartition
           , parent             => Parent
           , consumer           => subscribing
           , pending_acks       => []
           , upstream_cluster   => UpstreamClusterName
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
handle_message_set(#{ route              := Route
                    , upstream_cluster   := Cluster
                    , upstream_partition := Partition
                    } = State, Pid, MsgSet) ->
  #route{ upstream = {_UpstreamClientId, Topic}
        , options  = Options
        } = Route,
  #{consumer := Pid} = State, %% assert
  RepartStrategy = brucke_lib:get_repartitioning_strategy(Options),
  #kafka_message_set{high_wm_offset = HighWmOffset} = MsgSet,
  ?MX_HIGH_WM_OFFSET(Cluster, Topic, Partition, HighWmOffset),
  ?MX_TOTAL_VOLUME(Cluster, Topic, Partition, msg_set_bytes(MsgSet)),
  NewState = State#{high_wm_offset => HighWmOffset},
  do_handle_message_set(NewState, MsgSet, RepartStrategy).

do_handle_message_set(#{ route        := Route
                       , pending_acks := PendingAcks
                       } = State, MsgSet, strict_p2p) ->
  #kafka_message_set{ topic     = Topic
                    , partition = Partition
                    , messages  = Messages
                    } = MsgSet,
  #route{ upstream = {_UpstreamClientId, Topic}
        , downstream = {DownstreamClientId, DownstreamTopic}
        } = Route,
  %% lists:last/1 is safe here because brod never sends empty message set
  #kafka_message{offset = LastOffset} = lists:last(Messages),
  KafkaKvList =
    lists:map(
      fun(#kafka_message{key = Key, value = Value}) ->
        {ensure_binary(Key), ensure_binary(Value)}
      end, Messages),
  {ok, CallRef} = brod:produce(DownstreamClientId, DownstreamTopic,
                               Partition, <<>>, KafkaKvList),
  State#{pending_acks := PendingAcks ++ [?UNACKED(CallRef, LastOffset)]};
do_handle_message_set(#{ route        := Route
                       , pending_acks := PendingAcks
                       } = State, MsgSet, RepartStrategy) ->
  #kafka_message_set{ topic    = Topic
                    , messages = Messages
                    } = MsgSet,
  #route{ upstream = {_UpstreamClientId, Topic}
        , downstream = {DownstreamClientId, DownstreamTopic}
        } = Route,
  NewPendingAcks =
    lists:map(
      fun(#kafka_message{ offset = Offset
                        , key    = Key
                        , value  = Value
                        }) ->
        PartitionFun = repartition_fun(RepartStrategy),
        {ok, CallRef} = brod:produce(DownstreamClientId, DownstreamTopic,
                                     PartitionFun,
                                     ensure_binary(Key),
                                     ensure_binary(Value)),
        ?UNACKED(CallRef, Offset)
      end, Messages),
  State#{pending_acks := PendingAcks ++ NewPendingAcks}.

ensure_binary(undefined)           -> <<>>;
ensure_binary(B) when is_binary(B) -> B.

-spec handle_produce_reply(state(), #brod_produce_reply{}) -> state().
handle_produce_reply(#{ pending_acks       := PendingAcks
                      , parent             := Parent
                      , upstream_cluster   := UpstreamCluster
                      , upstream_partition := UpstreamPartition
                      , consumer           := ConsumerPid
                      , route              := Route
                      , high_wm_offset     := HighWmOffset
                      } = State, Reply) ->
  #brod_produce_reply{ call_ref = CallRef
                     , result   = brod_produce_req_acked %% assert
                     } = Reply,
  #route{upstream = {_UpstreamClientId, UpstreamTopic}} = Route,
  Offset =
    case lists:keyfind(CallRef, 1, PendingAcks) of
      ?UNACKED(CallRef, Offset_) ->
        Offset_;
      _ ->
        erlang:exit({unexpected_produce_reply, Route, UpstreamPartition,
                     PendingAcks, CallRef})
    end,
  PendingAcks1 =
    lists:keyreplace(CallRef, 1, PendingAcks, ?ACKED(CallRef, Offset)),
  {OffsetToAck, NewPendingAcks} = remove_acked_header(PendingAcks1, false),
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

-spec remove_acked_header(pending_acks(), false | offset()) ->
        {false | offset(), pending_acks()}.
remove_acked_header([], LastOffset) ->
  {LastOffset, []};
remove_acked_header([?UNACKED(_CallRef, _Offset) | _] = Pending, LastOffset) ->
  {LastOffset, Pending};
remove_acked_header([?ACKED(_CallRef, Offset) | Rest], _LastOffset) ->
  remove_acked_header(Rest, Offset).

-spec handle_consumer_down(state(), pid()) -> state().
handle_consumer_down(#{consumer := Pid} = _State, Pid) ->
  %% maybe start a send_after retry timer
  erlang:exit(consumer_down);
handle_consumer_down(State, _UnknownPid) ->
  State.

%% @private Return a partition or a partitioner function.
repartition_fun(key_hash) ->
  fun(_Topic, PartitionCount, Key, _Value) ->
    {ok, erlang:phash2(Key, PartitionCount)}
  end;
repartition_fun(random) ->
  fun(_Topic, PartitionCount, _Key, _Value) ->
    {ok, crypto:rand_uniform(0, PartitionCount)}
  end.

msg_set_bytes(#kafka_message_set{messages = Messages}) ->
  msg_set_bytes(Messages, 0).

msg_set_bytes([], Bytes) -> Bytes;
msg_set_bytes([#kafka_message{key = K, value = V} | Rest], Bytes) ->
  msg_set_bytes(Rest, Bytes + msg_bytes(K) + msg_bytes(V)).

msg_bytes(undefined)           -> 0;
msg_bytes(B) when is_binary(B) -> erlang:size(B).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
