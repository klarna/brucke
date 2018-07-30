%%%
%%%   Copyright (c) 2016-2018 Klarna Bank AB (publ)
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

-include("brucke_int.hrl").

-type partition() :: brod:partition().
-type offset() :: brod:offset().
-type state() :: #{}.
-type pending_acks() :: brucke_backlog:backlog().
-type cb_state() :: brucke_filter:cb_state().

-define(SUBSCRIBE_RETRY_LIMIT, 3).
-define(SUBSCRIBE_RETRY_SECONDS, 2).

%% Because the upstream messages might be dispatched to
%% different downstream partitions, there is no single downstream
%% producer process to monitor.
%% Instead, we periodically send a loop-back message to check if
%% the producer pids are still alive
-define(CHECK_PRODUCER_DELAY, timer:seconds(30)).
-define(CHECK_PRODUCER_MSG, check_producer).

-define(kafka_ack(UpstreamOffset, Ref), {kafka_ack, UpstreamOffset, Ref}).

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
  UpstreamClusterName = brucke_config:get_cluster_name(UpstreamClientId),
  State = #{ route              => Route
           , upstream_partition => UpstreamPartition
           , parent             => Parent
           , consumer           => subscribing
           , pending_acks       => brucke_backlog:new()
           , upstream_cluster   => UpstreamClusterName
           },
  Pid = proc_lib:spawn_link(
          fun() ->
              {ok, CbState} = brucke_filter:init(FilterModule, UpstreamTopic,
                                                 UpstreamPartition, InitArg),
              loop(State#{filter_cb_state => CbState})
          end),
  Pid ! {subscribe, BeginOffset, 0},
  _ = erlang:send_after(?CHECK_PRODUCER_DELAY, Pid, ?CHECK_PRODUCER_MSG),
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
    Msg ->
      ?MODULE:loop(handle_msg(State, Msg))
  end.

-spec handle_msg(state(), term()) -> state() | no_return().
handle_msg(State, {subscribe, BeginOffset, Count}) ->
  subscribe(State, BeginOffset, Count);
handle_msg(State, ?CHECK_PRODUCER_MSG) ->
  check_producer(State);
handle_msg(State, {Pid, #kafka_message_set{} = MsgSet}) ->
  handle_message_set(State, Pid, MsgSet);
handle_msg(State, ?kafka_ack(UpstreamOffset, Ref)) ->
  handle_produce_reply(State, UpstreamOffset, Ref);
handle_msg(State, {'DOWN', _Ref, process, Pid, _Reason}) ->
  handle_consumer_down(State, Pid);
handle_msg(_State, {_BrodConsumerPid,
                    #kafka_fetch_error{ topic = Topic
                                      , partition = Partition
                                      , error_code = 'UnknownTopicOrPartition'
                                      }}) ->
  lager:info("Topic ~s deleted? "
             "subscriber for partition ~p is exiting with normal reason",
             [Topic, Partition]),
  erlang:exit(normal);
handle_msg(_State, Unknown) ->
  erlang:exit({unknown_message, Unknown}).

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
  PartCnt = brod_client:get_partitions_count(DownstreamClientId, DownstreamTopic),
  FilterFun =
    fun(#kafka_message{ offset = Offset
                      , key = Key
                      , value = Value
                      , headers = Headers
                      } = Msg, CbStateIn) ->
        {FilterResult, NewCbState} =
          brucke_filter:filter(FilterModule, Topic, Partition, Offset,
                               Key, Value, Headers, CbStateIn),
        {make_batch(Msg, FilterResult), NewCbState}
    end,
  ProduceFun =
    fun(#{key := Key} = Msg, Cb) ->
        DownstreamPartition = partition(PartCnt, Partition, RepartStrategy, Key),
        {ok, ProducerPid} = brod:get_producer(DownstreamClientId, DownstreamTopic, DownstreamPartition),
        case brod:produce_cb(ProducerPid, Key, Msg, Cb) of
          ok -> {ok, ProducerPid};
          {error, Reason} -> erlang:exit(Reason)
        end
    end,
  {NewPendingAcks, NewCbState} =
    produce(FilterFun, ProduceFun, Messages, PendingAcks, CbState),
  handle_acked(State#{ pending_acks := NewPendingAcks
                     , filter_cb_state := NewCbState
                     }).

%% Make a batch input for downstream producer
make_batch(_Message, false) ->
  %% discard message
  [];
make_batch(#kafka_message{ ts_type = TsType
                         , ts = Ts
                         , key = Key
                         , value = Value
                         , headers = Headers
                         }, true) ->
  %% to downstream as-is
  [mk_msg(Key, Value, resolve_ts(TsType, Ts), Headers)];
make_batch(#kafka_message{ ts_type = TsType
                         , ts = Ts
                         }, {K, V}) ->
  %% old version filter return format k-v (without timestamp)
  [mk_msg(K, V, resolve_ts(TsType, Ts), [])];
make_batch(#kafka_message{}, {T, K, V}) ->
  %% old version filter return format t-k-v
  [mk_msg(K, V, T, [])];
make_batch(#kafka_message{}, L) when is_list(L) ->
  %% filter retruned a batch
  F = fun({K, V}) -> mk_msg(K, V, now_ts(), []);
         ({T, K, V}) -> mk_msg(K, V, T, []);
         (M) when is_map(M) -> M
      end,
  lists:map(F, L).

mk_msg(K, V, T, Headers) ->
  #{key => K, value => V, ts => T, headers => Headers}.

now_ts() -> kpro_lib:now_ts().

resolve_ts(create, Ts) when Ts > 0 -> Ts;
resolve_ts(_, _) -> now_ts().

-spec produce(fun((brod:message(), cb_state()) -> brod:batch_input()),
              fun((brod:batch_input()) -> {ok, pid()}),
              [#kafka_message{}], pending_acks(),
              cb_state()) -> {pending_acks(), cb_state()}.
produce(_FilterFun, _ProduceFun, [], PendingAcks, CbState) ->
  {PendingAcks, CbState};
produce(FilterFun, ProduceFun,
        [#kafka_message{offset = Offset} = Msg | Rest],
        PendingAcks0, CbState0) ->
  {FilterResult, CbState} = FilterFun(Msg, CbState0),
  Caller = self(),
  PendingRefs =
    case FilterResult of
      [] -> []; %% discard this message
      Batch ->
        lists:map(
          fun(OneMsg) ->
              Ref = make_ref(),
              Cb = fun(_, _) -> Caller ! ?kafka_ack(Offset, Ref) end,
              {ok, Pid} = ProduceFun(OneMsg, Cb),
              {Pid, Ref}
          end, Batch)
    end,
  PendingAcks = brucke_backlog:add(Offset, PendingRefs, PendingAcks0),
  produce(FilterFun, ProduceFun, Rest, PendingAcks, CbState).

-spec handle_produce_reply(state(), offset(), reference()) -> state().
handle_produce_reply(#{pending_acks := PendingAcks0} = State, UpstreamOffset, Ref) ->
  PendingAcks = brucke_backlog:ack(UpstreamOffset, Ref, PendingAcks0),
  handle_acked(State#{pending_acks := PendingAcks}).

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
  {OffsetToAck, NewPendingAcks} = brucke_backlog:prune(PendingAcks),
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

%% Return 'true' if ALL producers of unacked requests are still alive.
-spec check_producer(state()) -> state() | no_return().
check_producer(#{pending_acks := Pendings} = State) ->
  Pids = brucke_backlog:get_producers(Pendings),
  NewState =
    case lists:all(fun erlang:is_process_alive/1, Pids) of
      true  -> State;
      false -> erlang:exit(producer_down)
    end,
  _ = erlang:send_after(?CHECK_PRODUCER_DELAY, self(), ?CHECK_PRODUCER_MSG),
  NewState.

-spec handle_consumer_down(state(), pid()) -> state().
handle_consumer_down(#{consumer := Pid} = _State, Pid) ->
  erlang:exit(consumer_down);
handle_consumer_down(State, _UnknownPid) ->
  State.

-spec partition(integer(), partition(), repartitioning_strategy(), binary()) ->
        brod_partition_fun().
partition(_PartitionCount, UpstreamPartition, strict_p2p, _Key) ->
  UpstreamPartition;
partition(PartitionCount, _UpstreamPartition, key_hash, Key) ->
  erlang:phash2(Key, PartitionCount);
partition(PartitionCount, _UpstreamPartition, random, _Key) ->
  rand:uniform(PartitionCount) - 1.

msg_set_bytes(#kafka_message_set{messages = Messages}) ->
  msg_set_bytes(Messages, 0).

msg_set_bytes([], Bytes) -> Bytes;
msg_set_bytes([#kafka_message{key = K, value = V,
                              headers = Headers} | Rest], Bytes) ->
  msg_set_bytes(Rest, Bytes + size(K) + size(V) + header_bytes(Headers)).

header_bytes([]) -> 0;
header_bytes([{K, V} | Rest]) -> size(K) + size(V) + header_bytes(Rest).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
