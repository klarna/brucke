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

%% The upstream topic consumer group member
-module(brucke_member).

-behaviour(gen_server).
-behaviour(brod_group_member).

-export([ start_link/1
        ]).

%% gen_server callbacks
-export([ code_change/3
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , init/1
        , terminate/2
        ]).

%% group coordinator callbacks
-export([ get_committed_offsets/2
        , assign_partitions/3
        , assignments_received/4
        , assignments_revoked/1
        ]).

-include("brucke_int.hrl").
-include_lib("brod/include/brod.hrl").

-type topic() :: kafka_topic().
-type partition() :: kafka_partition().
-type offset() :: kafka_offset().
-type state() :: #{}.

-define(SUBSCRIBER_RESTART_DELAY_SECONDS, 10).
-define(DEAD(Ts), {dead_since, Ts}).
-record(subscriber, { partition    :: partition()
                    , begin_offset :: offset()
                    , pid          :: pid() | ?DEAD(erlang:timestamp())
                    }).

%%%_* APIs =====================================================================

-spec start_link(route()) -> {ok, pid()} | {error, any()}.
start_link(Route) -> gen_server:start_link(?MODULE, Route, []).

%%%_* brod_group_member callbacks ==========================================

-spec get_committed_offsets(pid(), [{topic(), partition()}]) ->
            {ok, [{{topic(), partition()}, offset()}]}.
get_committed_offsets(_GroupMemberPid, _TopicPartitions) ->
  erlang:exit({no_impl, get_committed_offsets}).

-spec assign_partitions(pid(), [kafka_group_member()],
                        [{topic(), partition()}]) ->
                          [{kafka_group_member_id(),
                           [brod_partition_assignment()]}].
assign_partitions(_Pid, _Members, _TopicPartitions) ->
  erlang:exit({no_impl, assign_partitions}).

-spec assignments_received(pid(), kafka_group_member_id(),
                           kafka_group_generation_id(),
                           brod_received_assignments()) -> ok.
assignments_received(MemberPid, MemberId, GenerationId, Assignments) ->
  Msg = {assignments_received, MemberId, GenerationId, Assignments},
  gen_server:cast(MemberPid, Msg).

-spec assignments_revoked(pid()) -> ok.
assignments_revoked(GroupMemberPid) ->
  gen_server:cast(GroupMemberPid, assignments_revoked).

%%%_* gen_server callbacks =====================================================

init(Route) ->
  erlang:process_flag(trap_exit, true),
  self() ! {post_init, Route},
  {ok, #{}}.

handle_info({post_init, #route{} = Route}, State) ->
  {UpstreamClientId, UpstreamTopic} = Route#route.upstream,
  {DownstreamClientId, DownstreamTopic} = Route#route.downstream,
  GroupConfig = [{offset_commit_policy, commit_to_kafka_v2}
                ,{offset_commit_interval_seconds, 10}
                ],
  Options = Route#route.options,
  ConsumerConfig = brucke_lib:get_consumer_config(Options),
  ProducerConfig = maps:get(producer_config, Options, []),
  ok = brod:start_consumer(UpstreamClientId, UpstreamTopic, ConsumerConfig),
  ok = brod:start_producer(DownstreamClientId, DownstreamTopic, ProducerConfig),
  ConsumerGroupId = brucke_config:get_consumer_group_id(UpstreamClientId),
  {ok, Pid} =
    brod_group_coordinator:start_link(UpstreamClientId, ConsumerGroupId, [UpstreamTopic],
                                      GroupConfig, ?MODULE, self()),
  _ = send_loopback_msg(1, restart_dead_subscribers),
  {noreply, State#{ coordinator => Pid
                  , route       => Route
                  , subscribers => []
                  }};
handle_info(restart_dead_subscribers, State) ->
  {noreply, restart_dead_subscribers(State)};
handle_info({ack, Partition, Offset}, State) ->
  {noreply, handle_ack(State, Partition, Offset)};
handle_info({'EXIT', Pid, _Reason}, #{coordinator := Pid} = State) ->
  {stop, coordinator_down, State};
handle_info({'EXIT', Pid, Reason}, State) ->
  NewState = handle_subscriber_down(State, Pid, Reason),
  case are_all_subscribers_down(NewState) of
    true ->
      %% when all subscribers are down at the same time
      %% very likely brod client is down
      %% hence need a restart of the producers and consumers
      {stop, all_subscribers_down, NewState};
    false ->
      {noreply, NewState}
  end;
handle_info(Info, State) ->
  lager:info("Unknown info: ~p", [Info]),
  {noreply, State}.

handle_call(Call, _From, State) ->
  lager:info("Unknown call: ~p", [Call]),
  {noreply, State}.

handle_cast({assignments_received, MemberId, GenerationId, Assignments},
            #{ route       := Route
             , subscribers := Subscribers0
             } = State) ->
  ok = stop_subscribers(Subscribers0),
  Subscribers = start_subscribers(Route, Assignments),
  {noreply, State#{ member_id     => MemberId
                  , generation_id => GenerationId
                  , subscribers   := Subscribers
                  }};
handle_cast(assignments_revoked, #{subscribers := Subscribers} = State) ->
  ok = stop_subscribers(Subscribers),
  {noreply, State#{subscribers := []}};
handle_cast(Cast, State) ->
  lager:info("Unknown cast: ~p", [Cast]),
  {noreply, State}.

terminate(_Reason, #{coordinator := Coordinator} = _State) ->
  _ = brod_group_coordinator:commit_offsets(Coordinator),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

-spec stop_subscribers([#subscriber{}]) -> ok.
stop_subscribers([]) -> ok;
stop_subscribers([#subscriber{pid = Pid} | Rest]) ->
  case is_pid(Pid) of
    true  -> ok = brucke_subscriber:stop(Pid);
    false -> ok
  end,
  stop_subscribers(Rest).

start_subscribers(#route{} = Route, Assignments) ->
  lists:map(
    fun(#brod_received_assignment{ partition    = UpstreamPartition
                                 , begin_offset = Offset
                                 }) ->
      {ok, Pid} = brucke_subscriber:start_link(Route, UpstreamPartition, Offset),
      #subscriber{ partition    = UpstreamPartition
                 , begin_offset = Offset
                 , pid          = Pid
                 }
    end, Assignments).

handle_ack(#{ subscribers   := Subscribers
            , coordinator   := Coordinator
            , generation_id := GenerationId
            , route         := Route
            } = State, Partition, Offset) ->
  case lists:keyfind(Partition, #subscriber.partition, Subscribers) of
    #subscriber{} = Subscriber ->
      NewSubscriber = Subscriber#subscriber{begin_offset = Offset + 1},
      NewSubscribers = lists:keyreplace(Partition, #subscriber.partition,
                                        Subscribers, NewSubscriber),
      #route{upstream = {_UpstreamClientId, UpstreamTopic}} = Route,
      ok = brod_group_coordinator:ack(Coordinator, GenerationId, UpstreamTopic,
                                      Partition, Offset),
      State#{subscribers := NewSubscribers};
    false ->
      lager:info("discarded ack ~s:~w:~w",
                 [fmt_route(Route), Partition, Offset]),
      State
  end.

handle_subscriber_down(#{ subscribers := Subscribers
                        , route       := Route
                        } = State, Pid, Reason) ->
  case lists:keyfind(Pid, #subscriber.pid, Subscribers) of
    #subscriber{partition = Partition} = Subscriber ->
      lager:error("subscriber ~s:~p down, reason:\n~p",
                  [fmt_route(Route), Partition, Reason]),
      NewSubscriber = Subscriber#subscriber{pid = ?DEAD(os:timestamp())},
      NewSubscribers = lists:keyreplace(Partition, #subscriber.partition,
                                        Subscribers, NewSubscriber),
      State#{subscribers := NewSubscribers};
    false ->
      %% stale down message
      State
  end.

send_loopback_msg(TimeoutSeconds, Msg) ->
  erlang:send_after(timer:seconds(TimeoutSeconds), self(), Msg).

restart_dead_subscribers(#{ route       := Route
                          , subscribers := Subscribers
                          } = State) ->
  _ = send_loopback_msg(1, restart_dead_subscribers),
  State#{subscribers := restart_dead_subscribers(Route, Subscribers)}.

restart_dead_subscribers(_Route, []) -> [];
restart_dead_subscribers(Route, [#subscriber{ pid          = ?DEAD(Ts)
                                            , partition    = Partition
                                            , begin_offset = BeginOffset
                                            } = S | Rest]) ->
  Elapsed = timer:now_diff(os:timestamp(), Ts),
  case Elapsed > ?SUBSCRIBER_RESTART_DELAY_SECONDS * 1000000 of
    true ->
      {ok, Pid} = brucke_subscriber:start_link(Route, Partition, BeginOffset),
      [S#subscriber{pid = Pid} | restart_dead_subscribers(Route, Rest)];
    false ->
      [S | restart_dead_subscribers(Route, Rest)]
  end;
restart_dead_subscribers(Route, [#subscriber{pid = Pid} = S | Rest]) ->
  true = is_pid(Pid), %% assert
  [S | restart_dead_subscribers(Route, Rest)].

-spec are_all_subscribers_down(state()) -> boolean().
are_all_subscribers_down(#{subscribers := []}) ->
  false;
are_all_subscribers_down(#{subscribers := Subscribers}) ->
  lists:all(fun(#subscriber{pid = ?DEAD(_)}) -> true;
               (_                          ) -> false
            end, Subscribers).

-spec fmt_route(route()) -> iodata().
fmt_route(Route) -> brucke_lib:fmt_route(Route).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
