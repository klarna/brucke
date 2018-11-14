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

-module(brucke_app).
-behaviour(application).

-export([ start/2
        , stop/1
        ]).

-export([ graphite_root_path/0
        , graphite_host/0
        , graphite_port/0
        , http_port/0
        , config_file/0
        ]).

-include("brucke_int.hrl").

%% App env getters
graphite_root_path() -> app_env(graphite_root_path).

graphite_host() -> app_env(graphite_host).

graphite_port() -> app_env(graphite_port).

http_port() -> app_env(http_port, 8080).

config_file() -> app_env(config_file, {priv, "brucke.yml"}).

%% @private Application callback.
start(_Type, _Args) ->
  ok = maybe_update_env(),
  ok = add_filter_ebin_dirs(),
  brucke_sup:start_link().

%% @private Application callback.
stop(_State) ->
  ok.

maybe_update_env() ->
  VarSpecs =
    [ {"BRUCKE_GRAPHITE_ROOT_PATH", graphite_root_path, binary}
    , {"BRUCKE_GRAPHITE_HOST", graphite_host, string}
    , {"BRUCKE_GRAPHITE_PORT", graphite_port, integer}
    , {"BRUCKE_HTTP_PORT", http_port, integer}
    , {"BRUCKE_FILTER_EBIN_PATHS", filter_ebin_dirs, fun parse_paths/1}
    , {"BRUCKE_CONFIG_FILE", config_file, string}
    ],
  maybe_update_env(VarSpecs).

maybe_update_env([]) -> ok;
maybe_update_env([{EnvVarName, AppVarName, Type} | VarSpecs]) ->
  ok = maybe_set_app_env(EnvVarName, AppVarName, Type),
  maybe_update_env(VarSpecs).

maybe_set_app_env(EnvVarName, AppVarName, Type) ->
  EnvVar = os:getenv(EnvVarName),
  case EnvVar of
    false -> ok;
    []    -> ok;
    X ->
      Value = transform_env_var_value(X, Type),
      logger:info("Setting app-env ~p from os-env ~s, value=~p",
                  [AppVarName, EnvVarName, Value]),
      application:set_env(?APPLICATION, AppVarName, Value)
  end,
  ok.

transform_env_var_value(S, string) -> S;
transform_env_var_value(S, binary) -> list_to_binary(S);
transform_env_var_value(I, integer) -> list_to_integer(I);
transform_env_var_value(I, Fun) -> Fun(I).

%% Parse comma or colon separated paths.
parse_paths(Paths) -> string:tokens(Paths, ":,").

%% @private Add extra ebin paths to code path.
%% There is usually no need to set `filter_ebin_dirs`
%% if brucke is used as a lib application for another project.
%% @end
-spec add_filter_ebin_dirs() -> ok.
add_filter_ebin_dirs() ->
  Dirs = application:get_env(?APPLICATION, filter_ebin_dirs, []),
  ok = code:add_pathsa(Dirs).

app_env(Key) -> app_env(Key, undefined).

app_env(Key, Def) ->
  application:get_env(?APPLICATION, Key, Def).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
