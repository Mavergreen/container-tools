#!/bin/sh
# platform: macOS-only -- cgo external link against the 10.9 SDK via go126's CC wrapper
# Build lazydocker (jesseduffield/lazydocker; a go.mod module, root main package) -> $OUT/lazydocker.
# A terminal UI for Docker. The go126 toolchain's default CC wrapper (go.env) forces the darwin/amd64
# min-10.9 target + SDK and links the legacy-support shim on the external link; nothing here.
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
"$GO" build -trimpath -ldflags "-linkmode=external -X main.version=${REF#v}" -o "$OUT/lazydocker" .
[ -f "$OUT/lazydocker" ] || { echo "no lazydocker binary produced" >&2; exit 1; }
echo "lazydocker: $OUT/lazydocker"
