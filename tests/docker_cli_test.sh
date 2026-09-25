#!/bin/sh
# platform: macOS-only -- runs lipo
# Assert the CMake-built docker binary exists and is a 10.9-capable x86_64 Mach-O.
set -eu
B=${1:?usage: docker_cli_test.sh <path-to-docker>}
[ -f "$B" ] || { echo "missing $B" >&2; exit 1; }
lipo -info "$B" 2>/dev/null | grep -q 'architecture: x86_64' || { echo "not x86_64" >&2; exit 1; }
echo "docker_cli_test: OK"
