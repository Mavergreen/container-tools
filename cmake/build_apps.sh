#!/bin/sh
# platform: host-agnostic
#   usage: sh cmake/build_apps.sh OUTDIR
#          Builds the Sparkle updater (container-tools-updater.app), the menu-bar app
#          (DockerMenu.app) and the hot-add helper (container-tools-hotplug), x86_64 for 10.9, with clang22 (cmake/fetch-clang22.sh) and the pinned 10.9
#          SDK, on Linux, a modern Mac or 10.9 alike: the host's cmake on Linux, shipyard-cmake on a Mac.
#          Refuses an updater that links docker (it updates docker, so it must not depend on it) or a
#          product tree (it must run while the product is replaced), or a helper that links libvix (it must
#          dlopen Fusion's at run time). Prints the two .app paths, then the helper's.
set -eu
OUT=${1:?usage: build_apps.sh OUTDIR}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAVERICKS_ROOT="$ROOT"; export MAVERICKS_ROOT
. "$ROOT/msc.sh"
if [ "$(uname -s)" = Linux ]; then
  sc="$(command -v cmake)" || { echo "build_apps.sh: no cmake on PATH" >&2; exit 1; }
else
  # shipyard-cmake lives in the /usr/local/mavergreen/bin link farm, which only login shells have on PATH.
  sc="$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)"
fi
sy="$SHIPYARD_SCRIPTS/.."
CL="$(sh "$ROOT/cmake/fetch-clang22.sh")"
# The build's compat guard and the checks below read Mach-O; off macOS only clang22's llvm tools can.
LIPO="${LIPO:-$CL/bin/llvm-lipo}"; OTOOL="${OTOOL:-$CL/bin/llvm-otool}"
NM="${NM:-$CL/bin/llvm-nm}"; STRINGS="${STRINGS:-$CL/bin/llvm-strings}"
export LIPO OTOOL NM STRINGS
for app in updater menubar hotplug; do
  bld="$OUT/container-tools-$app"
  rm -rf "$bld"
  "$sc" -S "$ROOT/$app" -B "$bld" -DCMAKE_TOOLCHAIN_FILE="$sy/MavericksToolchain.cmake" \
    -DMavericksShipyard_DIR="$sy" -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OBJC_COMPILER="$CL/bin/clang" -DCMAKE_OBJC_COMPILER_TARGET=x86_64-apple-macos10.9 \
    -DCMAKE_OBJC_FLAGS=--no-default-config -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld --ld-path=$CL/bin/ld64.lld" >&2
  "$sc" --build "$bld" >&2
done
upd="$OUT/container-tools-updater/container-tools-updater.app"
menu="$OUT/container-tools-menubar/DockerMenu.app"
deps="$("$OTOOL" -L "$upd/Contents/MacOS/container-tools-updater" | sed 1d)"
if printf '%s\n' "$deps" | grep -qi docker; then
  echo "build_apps.sh: the updater links a docker product (self-update circularity)" >&2; exit 1; fi
if printf '%s\n' "$deps" | grep -q 'usr/local/mavergreen/'; then
  echo "build_apps.sh: the updater links a product tree -- it could not run while replacing it" >&2; exit 1; fi
hp="$OUT/container-tools-hotplug/container-tools-hotplug"
if "$OTOOL" -L "$hp" | sed 1d | grep -qi vix; then
  echo "build_apps.sh: the hot-add helper links libvix -- it must dlopen Fusion's at run time" >&2; exit 1; fi
echo "$upd"
echo "$menu"
echo "$hp"
