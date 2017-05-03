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

%% A brucke config file is a YAML file.
%% Cluster names and client names must comply to erlang atom syntax.
%%
%% kafka_clusters:
%%   kafka_cluster_1:
%%     - localhost:9092
%%   kafka_cluster_2:
%%     - kafka-1:9092
%%     - kafka-2:9092
%% brod_clients:
%%   - client: brod_client_1
%%     cluster: kafka_cluster_1
%%     config:
%%       ssl:
%%         # start with "priv/" or provide full path
%%         cacertfile: priv/ssl/ca.crt
%%         certfile: priv/ssl/client.crt
%%         keyfile: priv/ssl/client.key
%% routes:
%%   - upstream_client: brod_client_1
%%     downstream_client: brod_client_1
%%     upstream_topics:
%%       - "topic_1"
%%     downstream_topic: "topic_2"
%%     repartitioning_strategy: strict_p2p
%%     default_begin_offset: earliest # optional
%%     compression: no_compression # optional
%%
-module(brucke_config).

-export([ init/0
        , is_configured_client_id/1
        , get_cluster_name/1
        , get_consumer_group_id/1
        , all_clients/0
        , all_routes/0
        ]).

-include("brucke_int.hrl").

-define(CONFIG_FILE_ENV_VAR_NAME, "BRUCKE_CONFIG_FILE").

-define(ETS, ?MODULE).

-type config_tag() :: atom() | string() | binary().
-type config_value() :: atom() | string() | integer().
-type config_entry() :: {config_tag(), config_value() | config()}.
-type config() :: [config_entry()].
-type client_id() :: brod:client_id().

%%%_* APIs =====================================================================

-spec init() -> ok | no_return().
init() ->
  File = get_file_path_from_config(),
  yamerl_app:set_param(node_mods, [yamerl_node_erlang_atom]),
  try
    [Configs] = yamerl_constr:file(File, [{erlang_atom_autodetection, true}]),
    do_init(Configs)
  catch C : E ->
      lager:emergency("failed to load brucke config file ~s: ~p:~p\n~p",
                      [File, C, E, erlang:get_stacktrace()]),
      exit({bad_brucke_config, File})
  end.

-spec is_configured_client_id(brod_client_id()) -> boolean().
is_configured_client_id(ClientId) when is_atom(ClientId) ->
  case lookup(ClientId) of
    false            -> false;
    {ClientId, _, _} -> true
  end.

-spec get_cluster_name(brod_client_id()) -> cluster_name().
get_cluster_name(ClientId) when is_atom(ClientId) ->
  {ClientId, ClusterName, _Config} = lookup(ClientId),
  ClusterName.

-spec get_consumer_group_id(brod_client_id()) -> consumer_group_id().
get_consumer_group_id(ClientId) when is_atom(ClientId) ->
  iolist_to_binary([get_cluster_name(ClientId), "-brucke-cg"]).

-spec all_clients() -> [client()].
all_clients() ->
  [{ClientId,
    begin
      {ClusterName, Endpoints} = lookup(ClusterName),
      Endpoints
    end,
    ClientConfig
   } || {ClientId, ClusterName, ClientConfig} <- ets:tab2list(?ETS)].

-spec all_routes() -> [route()].
all_routes() -> brucke_routes:all().

%%%_* Internal functions =======================================================

-spec get_file_path_from_config() -> filename() | no_return().
get_file_path_from_config() ->
  case os:getenv("BRUCKE_CONFIG_FILE") of
    false ->
      case application:get_env(brucke, config_file) of
        {ok, Path0} ->
          Path = assert_file(Path0),
          lager:info("Using brucke config file from application environment "
                     "'config_file': ~p", [Path]),
          Path;
        ?undef ->
          lager:emergency("Brucke config file not found! "
                          "It can either be specified by "
                          "environment variable ~s, "
                          "or in ~p application environment (sys.config)",
                          [?CONFIG_FILE_ENV_VAR_NAME, ?APPLICATION]),
          exit(brucke_config_not_found)
      end;
    Path ->
      lager:info("Using brucke config file from OS env ~s: ~s",
                 [?CONFIG_FILE_ENV_VAR_NAME, Path]),
      assert_file(Path)
  end.

-spec assert_file(filename() | {priv, filename()}) -> filename() | no_return().
assert_file({priv, Path}) ->
  assert_file(filename:join(code:priv_dir(?APPLICATION), Path));
assert_file(Path) ->
  case filelib:is_regular(Path) of
    true ->
      Path;
    false ->
      lager:emergency("~s is not a regular file", [Path]),
      exit({bad_brucke_config_file, Path})
  end.

-spec do_init([config()]) -> ok | no_return().
do_init(Configs) ->
  Kf = fun(K) ->
         case lists:keyfind(K, 1, Configs) of
           {K, V} ->
             V;
           false ->
             lager:emergency("kafka_cluster is not found in config"),
             exit({mandatory_config_entry_not_found, K})
         end
       end,
  Clusters = Kf(kafka_clusters),
  Clients = Kf(brod_clients),
  Routes = Kf(routes),
  case ets:info(?ETS) of
    ?undef ->
      ok;
    _ ->
      lager:emergency("config already loaded"),
      exit({?ETS, already_created})
  end,
  ?ETS = ets:new(?ETS, [named_table, protected, set]),
  try
    init(Clusters, Clients, Routes)
  catch
    exit : Reason ->
      ok = destroy(),
      erlang:exit(Reason);
    error : Reason ->
      ok = destroy(),
      erlang:exit({error, Reason, erlang:get_stacktrace()})
  end.

-spec destroy() -> ok.
destroy() ->
  try
    ets:delete(?ETS),
    ok
  catch error : badarg ->
    ok
  end.

lookup(Key) ->
  case ets:lookup(?ETS, Key) of
    []  -> false;
    [R] -> R
  end.

-spec init(config(), config(), config()) -> ok | no_return().
init(Clusters, _, _) when not is_list(Clusters) orelse Clusters == [] ->
  lager:emergency("Expecting list of kafka clusters "
                  "Got ~P\n", [Clusters, 9]),
  exit(bad_cluster_list);
init(_, Clients, _) when not is_list(Clients) orelse Clients == [] ->
  lager:emergency("Expecting list of brod clients "
                  "Got ~P\n", [Clients, 9]),
  exit(bad_client_list);
init(_, _, Routes) when not is_list(Routes) orelse Routes == [] ->
  lager:emergency("Expecting list of brucke routes "
                  "Got ~P\n", [Routes, 9]),
  exit(bad_route_list);
init(Clusters, Clients, Routes) ->
  lists:foreach(
    fun(Cluster) ->
      {ClusterName, Endpoints} = validate_cluster(Cluster),
      case lookup(ClusterName) of
        false ->
          ok;
        {ClusterName, _} ->
          lager:emergency("Duplicated cluster name ~p", [ClusterName]),
          exit({duplicated_cluster_name, ClusterName})
      end,
      ets:insert(?ETS, {ClusterName, Endpoints})
    end, Clusters),
  lists:foreach(
    fun(Client) ->
      {ClientId, ClusterName, ClientConfig} = validate_client(Client),
      case lookup(ClientId) of
        false -> ok;
        _ ->
          lager:emergency("Duplicated brod client id ~p", [ClientId]),
          exit({duplicated_brod_client_id, ClientId})
      end,
      case lookup(ClusterName) of
        false ->
          lager:emergency("Cluster name ~s for client ~p is not found",
                          [ClusterName, ClientId]),
          exit({cluster_not_found_for_client, ClusterName, ClientId});
        _ ->
          ok
      end,
      ets:insert(?ETS, {ClientId, ClusterName, ClientConfig})
    end, Clients),
  ok = brucke_routes:init(Routes).

validate_cluster({ClusterId, [_|_] = Endpoints}) ->
  {ensure_binary(ClusterId),
   [validate_endpoint(Endpoint) || Endpoint <- Endpoints]};
validate_cluster(Other) ->
  lager:emergency("Expecing cluster config with cluster id "
                  "and a list of hostname:port endpoints"),
  exit({bad_cluster_config, Other}).

validate_client(Client) ->
  try
    {_, ClientId} = lists:keyfind(client, 1, Client),
    {_, ClusterName} = lists:keyfind(cluster, 1, Client),
    Config0 = proplists:get_value(config, Client, []),
    Config = validate_client_config(ClientId, Config0),
    {ensure_atom(ClientId),
     ensure_binary(ClusterName),
     Config}
  catch
    error:Reason ->
      lager:emergency("Bad brod client config: ~P.\nreason=~p\nstack=~p",
                      [Client, 9, Reason, erlang:get_stacktrace()]),
      exit(bad_client_config)
  end.

ensure_atom(A) when is_atom(A) -> A.

ensure_binary(A) when is_atom(A) ->
  ensure_binary(atom_to_list(A));
ensure_binary(L) when is_list(L) ->
  list_to_binary(L);
ensure_binary(B) when is_binary(B) ->
  B.

validate_endpoint(HostPort) when is_list(HostPort) ->
  case string:tokens(HostPort, ":") of
    [Host, Port] ->
      try
        {Host, list_to_integer(Port)}
      catch
        _ : _ ->
          exit_on_bad_endpoint(HostPort)
      end;
    _Other ->
      exit_on_bad_endpoint(HostPort)
  end;
validate_endpoint(Other) ->
  exit_on_bad_endpoint(Other).

exit_on_bad_endpoint(Bad) ->
  lager:emergency("Expecting endpoints string of patern Host:Port\n"
                  "Got ~P", [Bad, 9]),
  exit(bad_endpoint).

validate_client_config(ClientId, Config) when is_list(Config) ->
  lists:map(fun(ConfigEntry) ->
              do_validate_client_config(ClientId, ConfigEntry)
            end, Config);
validate_client_config(ClientId, Config) ->
  lager:emergency("Expecing client config to be a list for client ~p.\nGot:~p",
                  [ClientId, Config]),
  exit(bad_client_config).

%% @private
do_validate_client_config(ClientId, {ssl, Options}) ->
  {ssl, validate_ssl_option(ClientId, Options)};
do_validate_client_config(_ClientId, {_, _} = ConfigEntry) ->
  ConfigEntry;
do_validate_client_config(ClientId, Other) ->
  lager:emergency("Unknown client config entry for client ~p,"
                  "expecting kv-pair\nGot:~p", [ClientId, Other]),
  exit(bad_client_config_entry).

%% @private
-spec validate_ssl_option(client_id(), true | list()) ->
        boolean() | list() | none().
validate_ssl_option(_ClientId, true) ->
  true;
validate_ssl_option(ClientId, SslOptions) ->
  lists:foldl(
    fun(OptName, OptIn) ->
      validate_ssl_option(ClientId, OptIn, OptName)
    end, SslOptions, [ {mandatory, cacertfile}
                     , {optional, certfile}
                     , {optional, keyfile}
                     ]).

%% @private
-spec validate_ssl_option(client_id(), list(),
                          {mandatory | optional,
                           cacertfile | certfile | keyfile}) -> list() | none().
validate_ssl_option(ClientId, SslOptions, {MandatoryOr, OptName}) ->
  case lists:keyfind(OptName, 1, SslOptions) of
    {_, Filename0} ->
      Filename = validate_ssl_file(ClientId, Filename0),
      lists:keyreplace(OptName, 1, SslOptions, {OptName, Filename});
    false when MandatoryOr =:= mandatory ->
      lager:emergency("ssl option '~p' is not found for client ~p",
                      [OptName, ClientId]),
      exit(missing_ssl_option);
    false when MandatoryOr =:= optional ->
      SslOptions
  end.

%% @private
-spec validate_ssl_file(client_id(), filename()) -> filename() | none().
validate_ssl_file(ClientId, Filename) ->
  Path =
    case filename:split(Filename) of
      ["priv" | PrivPath] ->
        filename:join([code:priv_dir(?APPLICATION) | PrivPath]);
      _ ->
        Filename
    end,
  case filelib:is_regular(Path) of
    true ->
      Path;
    false ->
      lager:emergency("ssl file ~p not found for client ~p", [Path, ClientId]),
      exit(bad_ssl_file)
  end.

%%%_* Tests ====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

validate_ssl_files_test() ->
  ?assertException(exit, missing_ssl_option,
                   validate_ssl_option(client_id, [])),
  %% cacertfile is mandatory, and bad file should trigger exception
  ?assertException(exit, bad_ssl_file,
                   validate_ssl_option(client_id,
                                       [{cacertfile, "no-such-file"}])),
  %% certfile is optional but providing a bad file should still
  %% raise an exception
  ?assertException(exit, bad_ssl_file,
                   validate_ssl_option(client_id,
                                       [{cacertfile, "priv/ssl/ca.crt"},
                                        {certfile, "no-such-file"}])),
  %% OK case
  ?assertMatch([{cacertfile, _}],
               validate_ssl_option(client_id,
                                   [{cacertfile, "priv/ssl/ca.crt"}])),

  ?assertMatch([{cacertfile, _}, {keyfile, _}, {certfile, _}],
               validate_ssl_option(client_id,
                                   [{cacertfile, "priv/ssl/ca.crt"},
                                    {keyfile, "priv/ssl/client.key"},
                                    {certfile, "priv/ssl/client.crt"}
                                   ])),
  ?assertEqual(true,
               validate_ssl_option(client_id, true)).


-endif.

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
