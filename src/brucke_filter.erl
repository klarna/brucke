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

-export([ init/2
        , init/3
        , filter/5
        , filter/6
        ]).

-export_type([ filter_result/0
             ]).

-include("brucke_int.hrl").
-include_lib("brod/include/brod.hrl").

-type filter_result() :: boolean() | {kafka_key(), kafka_value()}.

%% Called when route worker (`brucke_member') start/restart.
%% The assumption now is that the callback should be stateless.
%% This is why there is no support for callback state returned.
%% i.e. the filter is designed like a `lists:filtermap' but not `lists:foldl'.
-callback init(Upstream :: kafka_topic(), Downstream :: kafka_topic()) -> ok.

%% Called by assignment worker (`brucke_subscriber') for each message.
%% Return value implications:
%% true: No change, forward the message as-is to downstream
%% false: Discard the message
%% {NewKey, NewValue}: Produce the transformed new Key and Value to downstream.
-callback filter(Topic :: kafka_topic(),
                 Partition :: kafka_partition(),
                 Offset :: kafka_offset(),
                 Key :: kafka_key(),
                 Value :: kafka_value()) -> filter_result().

%% @doc Call callback module's init API
-spec init(module(), kafka_topic(), kafka_topic()) -> ok.
init(Module, UpstreamTopic, DownstreamTopic) ->
  Module:init(UpstreamTopic, DownstreamTopic).

%% @doc The default filter does not do anything special.
-spec init(kafka_topic(), kafka_topic()) -> ok.
init(_UpstreamTopic, _DownstreamTopic) -> ok.

%% @doc Filter message set.
-spec filter(module(), kafka_topic(), kafka_partition(), kafka_offset(),
             kafka_key(), kafka_value()) -> filter_result().
filter(Module, Topic, Partition, Offset, Key, Value) ->
  Module:filter(Topic, Partition, Offset, Key, Value).

%% @doc The default filter does nothing.
-spec filter(kafka_topic(), kafka_partition(), kafka_offset(),
             kafka_key(), kafka_value()) -> filter_result().
filter(_Topic, _Partition, _Offset, _Key, _Value) -> true.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
