#!/bin/sh
# platform: macOS-only -- cgo external link against the 10.9 SDK via go126's CC wrapper
# Build docker-machine -> $OUT/docker-machine. GOPATH/dep-era (no go.mod, vendored): GO111MODULE=off.
# The go126 toolchain's default CC wrapper (go.env) forces the darwin/amd64 min-10.9 target + SDK and
# links the legacy-support shim on the external link; nothing target-specific is passed here.
# Args: SRC OUT GO GOPATH APPLY   (APPLY: shipyard's apply_patches.sh)
# components/docker-machine/patches/*.patch is applied first, once (apply_patches.sh records the set in
# SRC; a changed set needs a fresh clone). 0001 lets `create` survive Fusion 8.5's guest-side shared
# folder mount failing on boot2docker's 5.15 kernel, which aborted every create before provisioning.
set -eu
SRC=$1; OUT=$2; GO=$3; GP=$4; APPLY=$5
mkdir -p "$OUT"
sh "$APPLY" "$SRC" "$(cd "$(dirname "$0")/.." && pwd)/components/docker-machine/patches"
cd "$SRC"
unset CC
export GOPATH="$GP" GO111MODULE=off CGO_ENABLED=1 GOARCH=amd64 GOTOOLCHAIN=local
"$GO" build -ldflags "-linkmode=external" -o "$OUT/docker-machine" ./cmd/docker-machine
[ -f "$OUT/docker-machine" ] || { echo "no docker-machine binary produced" >&2; exit 1; }
echo "docker-machine: $OUT/docker-machine"
