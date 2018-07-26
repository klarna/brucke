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

-ifndef(BRUCKE_INT_HRL).
-define(BRUCKE_INT_HRL, true).

-include_lib("brod/include/brod.hrl").

-define(APPLICATION, brucke).

-define(undef, undefined).

-type filename() :: string().

-type route_option_key() :: repartitioning_strategy
                          | producer_config
                          | consumer_config
                          | max_partitions_per_group_member
                          | filter_module
                          | filter_init_arg
                          | upstream_cg_id.

%% Message repartitioning strategy.
%% NOTE: For compacted topics, strict_p2p is the only choice.
%% key_hash:
%%   Hash the message key to downstream partition number
%% strict_p2p:
%%   Strictly map the upstream partition number to downstream partition
%%   number, worker will refuse to start if upstream and downstream
%%   topic has different number of partitions
%% random:
%%   Randomly distribute upstream messages to downstream partitions
-type repartitioning_strategy() :: key_hash
                                 | strict_p2p
                                 | random.

-define(DEFAULT_REPARTITIONING_STRATEGY, key_hash).

-define(IS_VALID_REPARTITIONING_STRATEGY(X),
        (X =:= key_hash orelse
         X =:= strict_p2p orelse
         X =:= random)).

-define(DEFAULT_FILTER_MODULE, brucke_filter).
-define(DEFAULT_FILTER_INIT_ARG, []).
-define(MAX_PARTITIONS_PER_GROUP_MEMBER, 12).
-define(DEFAULT_DEFAULT_BEGIN_OFFSET, latest).
-define(DEFAULT_COMPRESSION, no_compression).
-define(DEFAULT_REQUIRED_ACKS, -1).

-type consumer_group_id() :: binary().
-type hostname() :: string().
-type portnum() :: pos_integer().
-type endpoint() :: {hostname(), portnum()}.
-type cluster_name() :: binary().
-type cluster() :: {cluster_name(), [endpoint()]}.
-type client() :: {brod:client_id(), [endpoint()], brod:client_config()}.
-type route_options() :: [{route_option_key(), term()}]
                       | #{route_option_key() => term()}.
-type topic_name() :: atom() | string() | binary().

-type upstream() :: {brod:client_id(), brod:topic()}.
-type downstream() :: {brod:client_id(), brod:topic()}.

-record(route, { upstream   :: upstream()
               , downstream :: downstream()
               , options    :: route_options()
               , reason     :: binary()
               }).

-type route() :: #route{}.
-type raw_route() :: proplists:proplist().

-ifndef(APPLICATION).
-define(APPLICATION, brucke).
-endif.

-define(I2B(I), list_to_binary(integer_to_list(I))).

%% counter and gauge
-define(INC(Name, Value), brucke_metrics:inc(Name, Value)).
-define(SET(Name, Value), brucke_metrics:set(Name, Value)).
-define(TOPIC(Topic), brucke_metrics:format_topic(Topic)).

%% Metric names
-define(MX_TOTAL_VOLUME(Cluster, Topic, Partition, Bytes),
        ?INC([Cluster, ?TOPIC(Topic), ?I2B(Partition), <<"bytes">>], Bytes)).

-define(MX_HIGH_WM_OFFSET(Cluster, Topic, Partition, Offset),
        ?SET([Cluster, ?TOPIC(Topic), ?I2B(Partition), <<"high-wm">>], Offset)).
-define(MX_CURRENT_OFFSET(Cluster, Topic, Partition, Offset),
        ?SET([Cluster, ?TOPIC(Topic), ?I2B(Partition), <<"current">>], Offset)).
-define(MX_LAGGING_OFFSET(Cluster, Topic, Partition, Offset),
        ?SET([Cluster, ?TOPIC(Topic), ?I2B(Partition), <<"lagging">>], Offset)).

-ifdef(OTP_RELEASE).
-define(BIND_STACKTRACE(Var), :Var).
-define(GET_STACKTRACE(Var), ok).
-else.
-define(BIND_STACKTRACE(Var),).
-define(GET_STACKTRACE(Var), Var = erlang:get_stacktrace()).
-endif.


-endif.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
