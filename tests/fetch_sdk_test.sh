#!/bin/sh
# platform: host-agnostic
# Checks the pinned SDK fetch script (now the shared mavericks-shipyard copy, path
# passed as $1 from the ctest def). Verifies the pin + durable cache + tapi normalization.
set -eu
SDK_SH="${1:?fetch_sdk.sh path required (arg 1)}"
[ -r "$SDK_SH" ] || { echo "fetch_sdk_test: script missing: $SDK_SH" >&2; exit 1; }
PINS_SH="$(dirname "$SDK_SH")/sdk-pins.sh"
[ -r "$PINS_SH" ] || { echo "fetch_sdk_test: sdk-pins.sh missing beside $SDK_SH" >&2; exit 1; }
grep -q 'fcf88ce8ff0dd3248b97f4eb81c7909f2cc786725de277f4d05a2b935cc49de0' "$PINS_SH" \
  || { echo "fetch_sdk_test: pinned SHA-256 absent" >&2; exit 1; }
# Default cache must be durable and machine-local, not TMPDIR.
grep -q 'MAVERICKS_SDK_CACHE:-\$HOME/Library/Caches' "$SDK_SH" \
  || { echo "fetch_sdk_test: default cache not durable machine-local" >&2; exit 1; }
# Modern ld warns per MH_DYLIB_STUB stub; the fetch script converts them to .tbd via tapi.
grep -q 'tapi' "$SDK_SH" \
  || { echo "fetch_sdk_test: tapi stub-to-tbd normalization absent" >&2; exit 1; }
echo "fetch_sdk_test: pinned SDK present OK"
