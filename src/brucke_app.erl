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

-module(brucke_app).
-behaviour(application).

-export([ start/2
        , stop/1
        ]).

-include("brucke_int.hrl").

start(_Type, _Args) ->
  ok = maybe_update_env(),
  case brucke_sup:start_link() of
    Res = {ok, _} ->
      ok = brucke_health_check:init(),
      Res;
    Err -> Err
  end.

stop(_State) ->
  ok.

maybe_update_env() ->
  VarSpecs =
    [ {"BRUCKE_GRAPHITE_ROOT_PATH", graphite_root_path, binary}
    , {"BRUCKE_GRAPHITE_HOST", graphite_host, string}
    , {"BRUCKE_GRAPHITE_PORT", graphite_port, integer}
    , {"BRUCKE_HEALTHCHECK", healthcheck, boolean}
    , {"BRUCKE_HEALTHCHECK_PORT", healthcheck_port, integer}
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
      lager:info("Setting app-env ~p from os-env ~s, value=~p",
                 [AppVarName, EnvVarName, Value]),
      application:set_env(?APPLICATION, AppVarName, Value)
  end,
  ok.

transform_env_var_value(S, string) -> S;
transform_env_var_value(S, binary) -> list_to_binary(S);
transform_env_var_value(B, boolean) -> list_to_existing_atom(B);
transform_env_var_value(I, integer) -> list_to_integer(I).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
