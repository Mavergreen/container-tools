#!/bin/sh
# The already-built docker binary must pass the guard (x86_64, min-10.9, no post-10.9 imports).
# $1 = binary to check; $2 = path to the shared assert_binary_compatible.sh (from the ctest def).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="${1:-$ROOT/build/docker-cli/docker}"
GUARD="${2:?assert_binary_compatible.sh path required (arg 2)}"
[ -x "$BIN" ] || { echo "build docker-cli first (shipyard-cmake --build <dir>)" >&2; exit 1; }
sh "$GUARD" "$BIN"

# Teeth: the gate must be fail-closed, not a rubber stamp.
# (1) no binaries at all -> fail-closed, non-zero
if sh "$GUARD" >/dev/null 2>&1; then
  echo "compat_guard_test: FAIL — guard passed with no binaries (not fail-closed)" >&2; exit 1
fi
# (2) a missing path -> non-zero
if sh "$GUARD" "$ROOT/build/docker-cli/does-not-exist" >/dev/null 2>&1; then
  echo "compat_guard_test: FAIL — guard passed a missing binary" >&2; exit 1
fi
echo "compat_guard_test: OK"
