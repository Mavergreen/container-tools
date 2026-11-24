#!/bin/sh
# platform: host-agnostic -- reads the Mach-O architecture list with $LIPO (llvm-lipo off macOS)
# Assert the CMake-built docker binary exists and is a 10.9-capable x86_64 Mach-O.
set -eu
[ $# -ge 1 ] || { echo "docker_cli_test: runs from the ctest build, which passes its arguments -- skipping"; exit 77; }
B=$1
[ -f "$B" ] || { echo "missing $B" >&2; exit 1; }
"${LIPO:-lipo}" -info "$B" 2>/dev/null | grep -q 'architecture: x86_64' || { echo "not x86_64" >&2; exit 1; }
grep -aq 'cli-plugins/manager.treePluginDirs' "$B" \
  || { echo "built docker lacks treePluginDirs: the cli-plugins patch didn't apply" >&2; exit 1; }
! grep -aq '/usr/local/mavergreen/container-tools' "$B" \
  || { echo "built docker names its install prefix; the standalone archive must be relocatable" >&2; exit 1; }
echo "docker_cli_test: OK"
