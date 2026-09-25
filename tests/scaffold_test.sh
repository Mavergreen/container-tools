#!/bin/sh
# platform: host-agnostic
# Scaffold sanity: common.sh loads, build-mode detection returns a known value.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/cmake/common.sh"
mode=$(mavericks_docker_mode)
case "$mode" in
  native|cross) echo "scaffold_test: mode=$mode OK" ;;
  *) echo "scaffold_test: unexpected mode '$mode'" >&2; exit 1 ;;
esac
