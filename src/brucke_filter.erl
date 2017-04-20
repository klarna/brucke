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

-module(brucke_filter).

-export([ init/3
        , init/4
        , filter/6
        , filter/7
        ]).

-export_type([ cb_state/0
             , filter_result/0
             , filter_return/0
             ]).

-include("brucke_int.hrl").
-include_lib("brod/include/brod.hrl").

-type cb_state() :: term().
-type filter_result() :: boolean() | {kafka_key(), kafka_value()}.
-type filter_return() :: {filter_result(), cb_state()}.

-define(DEFAULT_STATE, []).

%% Called when route worker (`brucke_subscriber') start/restart.
-callback init(UpstreamTopic :: kafka_topic(),
               UpstreamPartition :: kafka_partition(),
               InitArg :: term()) -> {ok, cb_state()}.

%% Called by assignment worker (`brucke_subscriber') for each message.
%% Return value implications:
%% true: No change, forward the message as-is to downstream
%% false: Discard the message
%% {NewKey, NewValue}: Produce the transformed new Key and Value to downstream.
-callback filter(Topic :: kafka_topic(),
                 Partition :: kafka_partition(),
                 Offset :: kafka_offset(),
                 Key :: kafka_key(),
                 Value :: kafka_value(),
                 CbState :: cb_state()) -> filter_return().

%% @doc Call callback module's init API
-spec init(module(), kafka_topic(), kafka_partition(), term()) ->
        {ok, cb_state()}.
init(Module, UpstreamTopic, UpstreamPartition, InitArg) ->
  Module:init(UpstreamTopic, UpstreamPartition, InitArg).

%% @doc The default filter does not do anything special.
-spec init(kafka_topic(), kafka_partition(), term()) -> ok.
init(_UpstreamTopic, _UpstreamPartition, _InitArg) ->
  {ok, ?DEFAULT_STATE}.

%% @doc Filter message set.
-spec filter(module(), kafka_topic(), kafka_partition(), kafka_offset(),
             kafka_key(), kafka_value(), cb_state()) -> filter_return().
filter(Module, Topic, Partition, Offset, Key, Value, CbState) ->
  Module:filter(Topic, Partition, Offset, Key, Value, CbState).

%% @doc The default filter does nothing.
-spec filter(kafka_topic(), kafka_partition(), kafka_offset(),
             kafka_key(), kafka_value(), cb_state()) -> filter_result().
filter(_Topic, _Partition, _Offset, _Key, _Value, ?DEFAULT_STATE) ->
  {true, ?DEFAULT_STATE}.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
