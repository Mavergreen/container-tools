#!/bin/sh
# platform: host-agnostic
# Build boot2docker.iso from a pinned dragonflylee/boot2docker checkout, using its own
# Dockerfile recipe. Called by the boot2docker ExternalProject. Args (all explicit):
#   $1 SRC   absolute cloned source dir (has Dockerfile)
#   $2 OUT   absolute output dir (iso -> $OUT/boot2docker.iso)
#   $3 REF   pinned tag (used only to name the throwaway image)
#   $4 BASE  pinned base image, replacing upstream's FROM (see rebase_dockerfile.sh)
# Requires a reachable Docker daemon (CMake iso-mode configure already checked).
set -eu
[ $# -eq 4 ] || { echo "usage: $0 SRC OUT REF BASE" >&2; exit 64; }
SRC=$1; OUT=$2; REF=$3; BASE=$4
[ -f "$SRC/Dockerfile" ] || { echo "no Dockerfile in $SRC" >&2; exit 1; }
mkdir -p "$OUT"
IMG="container-tools-boot2docker:${REF}"
# Patch overlay: reset the (shared, cached) checkout to pristine first so applying is
# idempotent across re-runs, then apply every *.patch. Phase 1 carries one bitrot-repair
# patch (dead SKS keyservers -> HTTPS key import); later phases add modernization patches.
PATCHES="$(cd "$(dirname "$0")/.." && pwd)/components/boot2docker/patches"
git -C "$SRC" reset --hard HEAD >/dev/null 2>&1 || true
git -C "$SRC" clean -fdq 2>/dev/null || true
for p in "$PATCHES"/*.patch; do
  [ -e "$p" ] || continue
  echo "applying overlay $p"; git -C "$SRC" apply --3way "$p"
done
sh "$(dirname "$0")/rebase_dockerfile.sh" "$SRC/Dockerfile" "$BASE"
echo "base image: $BASE"
docker build -t "$IMG" "$SRC"
# The container emits the ISO on stdout (dragonflylee's recipe): capture to a temp then move.
tmp="$OUT/.boot2docker.iso.$$"
docker run --rm "$IMG" > "$tmp"
[ -s "$tmp" ] || { echo "empty iso produced" >&2; rm -f "$tmp"; exit 1; }
mv "$tmp" "$OUT/boot2docker.iso"
echo "boot2docker: $OUT/boot2docker.iso ($(wc -c < "$OUT/boot2docker.iso") bytes)"
