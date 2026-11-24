#!/bin/sh
# platform: macOS-only -- cgo external link against the 10.9 SDK via go126's CC wrapper
# Build docker-compose (Compose v2; a go.mod module) -> $OUT/docker-compose. The go126 toolchain's
# default CC wrapper (go.env) forces the darwin/amd64 min-10.9 target + SDK and links the legacy-support
# shim on the external link; nothing target-specific is passed here.
# Args: SRC OUT GO REF
set -eu
SRC=$1; OUT=$2; GO=$3; REF=$4
mkdir -p "$OUT"
cd "$SRC"
unset CC
export CGO_ENABLED=1 GOARCH=amd64 GOTOOLCHAIN=local
# Reproducible across hosts: -trimpath keeps host paths out of what Go stamps, and the prefix maps
# keep them out of cgo's C debug info (both spellings of the work dir; CGO_CFLAGS replaces Go's
# default -O2 -g, so that stays).
export CGO_CFLAGS="-O2 -g -ffile-prefix-map=$PWD=/src -ffile-prefix-map=$(pwd -P)=/src"
MOD=$(awk '/^module /{print $2; exit}' go.mod)   # -X tracks the module's major-version suffix (v2 -> v5)
"$GO" build -trimpath -ldflags "-linkmode=external -X $MOD/internal.Version=$REF" -o "$OUT/docker-compose" ./cmd
[ -f "$OUT/docker-compose" ] || { echo "no docker-compose binary produced" >&2; exit 1; }
echo "docker-compose: $OUT/docker-compose"
