#!/bin/sh
# platform: host-agnostic
# Build docker-compose (Compose v2; a go.mod module) -> $OUT/docker-compose. The go126 toolchain's
# default CC wrapper (go.env) forces the darwin/amd64 min-10.9 target + SDK and links the legacy-support
# shim on the external link; nothing target-specific is passed here.
# Args: SRC OUT GO REF
set -eu
SRC=$1; OUT=$2; GO=$3; REF=$4
mkdir -p "$OUT"
cd "$SRC"
unset CC
export CGO_ENABLED=1 GOARCH=amd64
MOD=$(awk '/^module /{print $2; exit}' go.mod)   # -X tracks the module's major-version suffix (v2 -> v5)
"$GO" build -ldflags "-linkmode=external -X $MOD/internal.Version=$REF" -o "$OUT/docker-compose" ./cmd
[ -f "$OUT/docker-compose" ] || { echo "no docker-compose binary produced" >&2; exit 1; }
echo "docker-compose: $OUT/docker-compose"
