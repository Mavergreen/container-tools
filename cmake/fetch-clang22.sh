#!/bin/sh
# platform: host-agnostic
#   usage: cmake/fetch-clang22.sh     prints the prefix of the clang22 release components/clang22/version pins, for
#          this host, through shipyard's fetch_clang22.sh: the Linux archive on Linux, the cross pkg on a modern
#          Mac, the native pkg on 10.9 (or the installed product at that release). Its clang.cfg reaches the
#          pinned 10.9 SDK: on Linux setup-sdk points it there; a pkg unpacked into the cache gets the SDK
#          link its sibling sdk109 product would have given it.
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/msc.sh"
d="$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$REPO_ROOT/components/clang22")"
for b in clang clang++ ld64.lld ld.lld llvm-ar llvm-ranlib llvm-nm llvm-strip llvm-lipo llvm-install-name-tool llvm-otool llvm-strings; do
  [ -x "$d/bin/$b" ] || { echo "fetch-clang22: $d lacks bin/$b" >&2; exit 1; }
done
for f in lib/libc++.a lib/librecaulk.a; do
  [ -f "$d/$f" ] || { echo "fetch-clang22: $d lacks $f" >&2; exit 1; }
done
sdk="$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh")"
l="$d/SDKs/MacOSX10.9.sdk"
host="${CLANG22_HOST:-}"; [ -n "$host" ] || { [ "$(uname -s)" = Linux ] && host=linux; } || :
if [ "$host" = linux ]; then
  if [ -L "$l" ] && [ "$(cd "$l" && pwd -P)" = "$(cd "$sdk" && pwd -P)" ]; then :; else "$d/bin/setup-sdk" "$sdk" >&2; fi
elif [ ! -d "$l/usr/include" ]; then
  [ -w "$d" ] || { echo "fetch-clang22: $d has no 10.9 SDK at $l and is not writable" >&2; exit 1; }
  if [ -L "$d/SDKs" ]; then rm "$d/SDKs"; fi
  mkdir -p "$d/SDKs"
  ln -sfn "$sdk" "$l"
fi
[ -d "$l/usr/include" ] || { echo "fetch-clang22: $l does not reach the pinned 10.9 SDK" >&2; exit 1; }
echo "$d"
