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

-module(brucke_lib).

-export([ log_skipped_route_alert/2
        , get_consumer_config/1
        , get_repartitioning_strategy/1
        , get_producer_config/1
        , fmt_route/1
        ]).

-include("brucke_int.hrl").

%%%_* APIs =====================================================================

-spec fmt_route(route()) -> iodata().
fmt_route(#route{upstream = Upstream, downstream = Downstream}) ->
  io_lib:format("~p -> ~p", [Upstream, Downstream]).

-spec log_skipped_route_alert(route() | raw_route(), iodata()) -> ok.
log_skipped_route_alert(#route{} = Route, Reasons) ->
  lager:alert("SKIPPING bad route: ~s\nREASON(s):~s",
              [fmt_route(Route), Reasons]),
  ok;
log_skipped_route_alert(Route, Reasons) ->
  lager:alert("SKIPPING bad route: ~p\nREASON(s):~s",
              [Route, Reasons]),
  ok.

-spec get_repartitioning_strategy(route_options()) -> repartitioning_strategy().
get_repartitioning_strategy(Options) ->
  maps:get(repartitioning_strategy, Options, ?DEFAULT_REPARTITIONING_STRATEGY).

-spec get_consumer_config(route_options()) -> brod_consumer_config().
get_consumer_config(Options) ->
  maybe_use_brucke_defaults(
    maps:get(consumer_config, Options, []),
    default_consumer_config()).

-spec get_producer_config(route_options()) -> brod_producer_config().
get_producer_config(Options) ->
  maybe_use_brucke_defaults(
    maps:get(producer_config, Options, []),
    default_producer_config()).

%%%_* Internal Functions =======================================================


%% @private use hard-coded defaults if not found in config
maybe_use_brucke_defaults(Config, []) ->
  Config;
maybe_use_brucke_defaults(Config, [{K, V} | Rest]) ->
  NewConfig =
    case lists:keyfind(K, 1, Config) of
      {K, _} -> Config;
      false  -> [{K, V} | Config]
    end,
  maybe_use_brucke_defaults(NewConfig, Rest).

%% @private The default values for brucke.
default_consumer_config() ->
  [ {prefetch_count, 12}
  , {begin_offset, latest}
  ].

%% @private Default producer config
default_producer_config() ->
  [ {max_linger_ms, 2000} %% 2 seconds
  , {max_linger_count, 100}
  , {max_batch_size, 800000} %% 800K
  , {ack_timeout, 10000} %% 10 seconds
  , {retry_backoff_ms, 1000}
  ].

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
