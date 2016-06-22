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

%% A brucke config file is a Erlang term file consist of 3 sections
%% 1. kafka clusters
%%    e.g. [{"kafka-cluster-1", [{"localhost", 9092}]}].
%% 2. brod clients
%%    e.g. [{brod_client_1, "kafka-cluster-1", _ClientConfig = [...]}].
%% 3. brucke routes
%%    e.g. [{{_Upstream = {brod_client_1, topic_1},
%%           {_Downstream = {brod_client_2, topic_2}},
%%           _Options = []
%%         ].
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

-type raw_client() :: {brod_client_id(), cluster_name(), brod_client_config()}.
-define(ETS, ?MODULE).

%%%_* APIs =====================================================================

-spec init() -> ok | no_return().
init() ->
  File = get_file_path_from_config(),
  case file:consult(File) of
    {ok, Configs} ->
      init(File, Configs);
    {error, Reason} ->
      lager:emergency("failed to load brucke config file ~s, reason:~p",
                      [File, Reason]),
      exit({bad_erlang_term_file, File})
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

-spec init(filename(), [term()]) -> ok | no_return().
init(_File, [Clusters, Clients, Routes]) ->
  ets:info(?ETS) =/= ?undef andalso exit({?ETS, already_created}),
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
  end;
init(File, L) ->
  lager:emergency("Expecting 3 sections in brucke config\n"
                  "1. Kafka Clusters\n"
                  "2. Brod Clients\n"
                  "3. Brucke Routes\n"
                  "seems ~s has ~p sections", [File, length(L)]),
  exit(bad_brucke_config_file).

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

-spec init([cluster()], [raw_client()], [raw_route()]) -> ok | no_return().
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
        {ClusterName, Endpoints0} ->
          lager:alert("Duplicated cluster name\n"
                      "overwritting endpoints: ~p\n"
                      "        with endpoints: ~p\n",
                      [Endpoints0, Endpoints]
                      )
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
  lager:emergency("Expecing cluster config of pattern {ClusterId, Endpoints}\n"
                  "Got: ~P", [Other, 9]),
  exit(bad_cluster_config).

validate_client({ClientId, ClusterName, Config}) when is_list(Config) ->
  {ensure_atom(ClientId),
   ensure_binary(ClusterName),
   Config};
validate_client(Other) ->
  lager:emergency("Expecing client config of pattern "
                  "{ClientId::atom(), ClusterName::string(), ClientConfig::list()}\n"
                  "Got: ~P", [Other, 9]),
  exit(bad_client_config).

ensure_atom(A) when is_atom(A) -> A.

ensure_binary(A) when is_atom(A) ->
  ensure_binary(atom_to_list(A));
ensure_binary(L) when is_list(L) ->
  list_to_binary(L);
ensure_binary(B) when is_binary(B) ->
  B.

validate_endpoint({Host, Port}) ->
  {ensure_string(Host),
   ensure_protnum(Port)};
validate_endpoint(Other) ->
  lager:emergency("Expecting endpoints of patern {Host, Port}\n"
                  "Got ~P", [Other, 9]),
  exit({bad_endpoint}).

ensure_string(A) when is_atom(A) -> atom_to_list(A);
ensure_string(B) when is_binary(B) -> binary_to_list(B);
ensure_string(L) when is_list(L)   -> L;
ensure_string(Other) ->
  lager:emergency("Unexpected string: ~P", [Other, 9]),
  exit({bad_string, Other}).

ensure_protnum(I) when is_integer(I) -> I;
ensure_protnum(X) ->
  lager:emergency("Unexpected port number ~P", [X, 9]),
  exit({bad_port_number, X}).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
