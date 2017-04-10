#!/bin/bash -e

THIS_DIR="$(dirname $(readlink -f $0))"
MAKEFILE="$THIS_DIR/../Makefile"
APP_SRC="$THIS_DIR/../src/brucke.app.src"
REBAR_CONFIG="$THIS_DIR/../rebar.config"

PROJECT_VERSION=$1

ESCRIPT=$(cat <<EOF
{ok, [{_,_,L}]} = file:consult('$APP_SRC'),
{vsn, Vsn} = lists:keyfind(vsn, 1, L),
io:put_chars(Vsn),
halt(0)
EOF
)

APP_VSN=$(erl -noshell -eval "$ESCRIPT")

if [ "$PROJECT_VERSION" != "$APP_VSN" ]; then
  echo "version discrepancy, PROJECT_VERSION is '$PROJECT_VERSION', vsn in app.src is '$APP_VSN'"
  exit 1
fi

ESCRIPT=$(cat <<-EOF
{ok, Config} = file:consult('$REBAR_CONFIG'),
{deps, Deps0} = lists:keyfind(deps, 1, Config),
LoopFun =
	fun L(eof, []) -> 0;
	    L(eof, Deps) -> io:format("deps not found in Makefile but defined in rebar.config\n~p\n", [Deps]), 1;
	    L(Line, Deps) ->
        {NameStr, Vsn} = case string:tokens(Line, "= \n") of
                           ["dep_" ++ NameStr_, "hex", Vsn_] -> {NameStr_, Vsn_};
                           ["dep_" ++ NameStr_, "git", _Url, Vsn_] -> {NameStr_, Vsn_}
                         end,
	      Name = list_to_atom(NameStr),
	      case lists:keyfind(Name, 1, Deps) of
          {_, V} ->
	          case V =:= Vsn of
	            true ->
	              NewDeps = lists:keydelete(Name, 1, Deps),
	              L(io:get_line([]), NewDeps);
	            false ->
	              io:format("dependency ~s version discrepancy, in Makefile: ~s, in rebar.config: ~s\n", [Name, Vsn, V]),
	              2
	          end;
	        false ->
	          io:format("dependency ~s defined in Makefile not found in rebar.config\n", [Name]),
	          3
	      end
  end,
halt(LoopFun(io:get_line([]), Deps0)).
EOF
)

grep -E "dep_.*\s=" $MAKEFILE | erl -noshell -eval "$ESCRIPT"

