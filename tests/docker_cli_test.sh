#!/bin/sh
# platform: macOS-only -- lipo reads the Mach-O architecture list
# Assert the CMake-built docker binary exists and is a 10.9-capable x86_64 Mach-O.
set -eu
[ $# -ge 1 ] || { echo "docker_cli_test: runs from the ctest build, which passes its arguments -- skipping"; exit 77; }
B=$1
[ -f "$B" ] || { echo "missing $B" >&2; exit 1; }
lipo -info "$B" 2>/dev/null | grep -q 'architecture: x86_64' || { echo "not x86_64" >&2; exit 1; }
grep -aq '/usr/local/mavergreen/container-tools/lib/docker/cli-plugins' "$B" \
  || { echo "built docker does not carry the container-tools cli-plugins search path (D2 patch not applied?)" >&2; exit 1; }
echo "docker_cli_test: OK"
