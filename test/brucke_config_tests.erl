%%%
%%%   Copyright (c) 2018 Klarna Bank AB (publ)
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
-module(brucke_config_tests).

-include_lib("eunit/include/eunit.hrl").

validate_client_config_test_() ->
  [ %% cacertfile is mandatory, and bad file should trigger exception
  ?_assertException(exit, bad_ssl_file,
                      validate_client_config([{ssl, [{cacertfile, "no-such-file"}]}])),
  %% certfile is optional but providing a bad file should still
  %% raise an exception
  ?_assertException(exit, bad_ssl_file,
                    validate_client_config([{ssl, [{cacertfile, "priv/ssl/ca.crt"},
                                                   {certfile, "no-such-file"}]}])),
  %% OK case
  ?_assertMatch([{ssl, [{cacertfile, _}]}],
                validate_client_config([{ssl, [{cacertfile, "priv/ssl/ca.crt"}]}])),

  ?_assertMatch([{ssl, [{cacertfile, _}, {keyfile, _}, {certfile, _}]}],
                validate_client_config([{ssl, [{cacertfile, "priv/ssl/ca.crt"},
                                              {keyfile, "priv/ssl/client.key"},
                                              {certfile, "priv/ssl/client.crt"}
                                             ]}])),
  ?_assertEqual([], validate_client_config([])),
  ?_assertEqual([{ssl, true}, {sasl, {plain, <<"foo">>, <<"bar">>}}],
                validate_client_config([{ssl, true},
                                        {sasl, [{username, foo},
                                                {password, bar}]}])),
  ?_assertEqual([{ssl, true}, {sasl, {scram_sha_256, <<"foo">>, <<"bar">>}}],
                validate_client_config([{ssl, true},
                                        {sasl, [{username, foo},
                                                {password, bar},
                                                {mechanism, scram_sha_256}]}])),
  ?_assertEqual([{sasl, {scram_sha_512, <<"foo">>, <<"bar">>}}],
                validate_client_config([{sasl, [{username, foo},
                                                {password, "bar"},
                                                {mechanism, scram_sha_512}]}]))
 ].

validate_client_config(Config) ->
  brucke_config:validate_client_config(client_id, Config).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
