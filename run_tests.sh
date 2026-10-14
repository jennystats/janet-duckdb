#!/bin/sh
# run_tests.sh - janet-duckdb smoke suite. SKIP semantics: absent libs
# skip, present-but-broken is a FAIL, never a skip.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -n "$JANET_PATH" ] || export JANET_PATH="$HOME/.local/lib/janet"
export JANET_PATH="$DIR:$JANET_PATH"

has_duckdb() { { [ -n "$DUCKDB_LIB" ] || [ -f "$HOME/.local/lib/duckdb/libduckdb.so" ] || ldconfig -p 2>/dev/null | grep -q libduckdb; } && { [ -n "$JANET_NUM_LIB" ] || [ -f "$HOME/.local/lib/janet-num/libjn.so" ]; }; }

fail=0
if has_duckdb; then
  if janet "$DIR/test/smoke-duckdb.janet" > /dev/null 2>&1; then
    echo "PASS smoke-duckdb.janet"
  else
    echo "FAIL smoke-duckdb.janet"
    janet "$DIR/test/smoke-duckdb.janet"
    fail=1
  fi
else
  echo "SKIP smoke-duckdb.janet (no libduckdb or libjn - run libs/install-duckdb.sh and libs from janet-num)"
fi

if [ "$fail" -eq 0 ]; then echo "RESULT: pass"; else echo "RESULT: fail"; exit 1; fi
