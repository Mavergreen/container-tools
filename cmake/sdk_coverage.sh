#!/bin/sh
# platform: macOS-only -- nm reads Mach-O symbols
# Prove every undefined dynamic import of each binary exists in the 10.9 SDK's
# library stubs OR is on the weak allowlist. Version-INDEPENDENT: no committed
# per-version reference needed. Fail-closed.
# Usage: sdk_coverage.sh [--fetch-script <path>] <binary> [<binary> ...]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$(dirname "$0")/common.sh"
export LC_ALL=C
# The shared fetch_sdk.sh location is passed by the caller (CMake knows
# MavericksShipyard_DIR); this script no longer ships its own copy.
FETCH_SCRIPT=""
if [ "${1-}" = "--fetch-script" ]; then FETCH_SCRIPT="$2"; shift 2; fi
[ -n "$FETCH_SCRIPT" ] || mavericks_docker_die "sdk_coverage.sh: --fetch-script <path> is required"
# Always verify against the SAME pinned 10.9 SDK, on box and CI alike — it is the
# reference contract, not the build host's system libs.
SDK=$(sh "$FETCH_SCRIPT")
[ -d "$SDK" ] || mavericks_docker_die "no pinned 10.9 SDK at $SDK"
# The 10.9 SDK ships Mach-O stub dylibs/frameworks (pre-.tbd): extract DEFINED
# (address-bearing) symbols via nm. Also handle .tbd text stubs if a future SDK
# bump uses them. Skip non-binaries.
STUBSYMS=$(mktemp "${TMPDIR:-/tmp}/container-tools-stubsyms.XXXXXX"); trap 'rm -f "$STUBSYMS"' EXIT
find "$SDK/usr/lib" "$SDK/System/Library/Frameworks" -type f 2>/dev/null | while IFS= read -r f; do
  case "$f" in
    # Parse (weak-)symbols arrays; a bare token grep would mangle names that
    # don't start with "_" (dyld_stub_binder). Arrays may span multiple lines.
    # "|| :": grep exits 1 on symbol-less tbds, which under set -e would
    # silently kill this whole extraction loop mid-stream.
    *.tbd) { tr '\n' ' ' < "$f" | grep -oE 'symbols: *\[[^]]*\]' \
             | sed "s/.*\[//; s/\]//" | tr ',' '\n' | sed "s/[ '\"]//g" | grep -v '^$'; } || : ;;
    *.h|*.hpp|*.plist|*.strings|*.modulemap|*.nib|*.png|*.a) : ;;
    *) nm -g "$f" 2>/dev/null | awk '$1 ~ /^[0-9a-fA-F]+$/ {print $NF}' ;;
  esac
done | sort -u > "$STUBSYMS"
[ -s "$STUBSYMS" ] || mavericks_docker_die "no SDK stub symbols extracted from $SDK"
ALLOW="$(dirname "$0")/weak_allowlist.txt"
[ -f "$ALLOW" ] || mavericks_docker_die "missing allowlist $ALLOW"
fail=0; checked=0
for b in "$@"; do
  [ -f "$b" ] || mavericks_docker_die "missing binary $b"
  checked=$((checked+1))
  undef=$(nm -u "$b" 2>/dev/null | awk '{print $NF}' | sort -u)
  [ -n "$undef" ] || mavericks_docker_die "no undefined symbols measured for $b"
  for s in $undef; do
    grep -qx "$s" "$STUBSYMS" && continue
    grep -qxF "$s" "$ALLOW" 2>/dev/null && continue
    echo "sdk coverage: $b imports '$s' not in 10.9 SDK and not allowlisted" >&2
    fail=1
  done
done
[ "$checked" -gt 0 ] || mavericks_docker_die "no binaries checked"
if [ "$fail" = 0 ]; then
  echo "sdk coverage: $checked binaries only import 10.9-available symbols"
else
  exit 1
fi
