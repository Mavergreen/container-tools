#!/bin/sh
# platform: host-agnostic
# Build docker/cli -> $OUT/docker. Compiled with go126-cross (cross) or the native go126 .pkg (box).
# The toolchain's default CC wrapper (set in $GOROOT/go.env) forces the darwin/amd64 min-10.9 target +
# the 10.9 SDK and links the legacy-support shim + the -Wl,-U weak-symbol allowances on the external
# link -- so nothing target-specific is passed here. `unset CC` so go.env's wrapper wins.
#   $1 SRC  cloned source   $2 OUT  output dir (-> $OUT/docker)   $3 GO  go binary   $4 REF  docker/cli tag
set -eu
SRC=$1; OUT=$2; GO=$3; REF=$4
VER=${REF#v}
mkdir -p "$OUT"
PATCHES="$(cd "$(dirname "$0")/.." && pwd)/components/docker-cli/patches"
git -C "$SRC" checkout -- .
for p in "$PATCHES"/*.patch; do
  [ -e "$p" ] || continue
  git -C "$SRC" apply "$p"
done
cd "$SRC"
ln -sf vendor.mod go.mod
ln -sf vendor.sum go.sum
rm -f ._go.mod ._go.sum   # NFS AppleDouble sidecars make the pinned clone look dirty (-> ".dirty" version)
COMMIT=$(git rev-parse --short HEAD)
unset CC
export CGO_ENABLED=1 GOARCH=amd64
"$GO" build -mod=vendor \
  -ldflags "-linkmode=external \
            -X github.com/docker/cli/cli/version.Version=$VER \
            -X github.com/docker/cli/cli/version.GitCommit=$COMMIT \
            -X github.com/docker/cli/cli/version.BuildTime=mavericks-$("$GO" version | awk '{print $3}')" \
  -o "$OUT/docker" ./cmd/docker
[ -f "$OUT/docker" ] || { echo "no docker binary produced" >&2; exit 1; }
echo "docker-cli: $OUT/docker"
