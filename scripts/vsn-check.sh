#!/bin/bash -e

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKEFILE="$THIS_DIR/../Makefile"
APP_SRC="$THIS_DIR/../src/brucke.app.src"

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

