#!/bin/sh
# platform: host-agnostic
# build_docker_compose.sh must stamp internal.Version via the module path read
# from go.mod, not a hardcoded major-version path (v2 -> v5 broke silently).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S="$ROOT/cmake/build_docker_compose.sh"
[ -f "$S" ] || { echo "docker_compose_test: script missing" >&2; exit 1; }
grep -q 'docker/compose/v[0-9]' "$S" \
  && { echo "docker_compose_test: hardcoded module major version in -X path" >&2; exit 1; }
grep -q 'go\.mod' "$S" \
  || { echo "docker_compose_test: module path not derived from go.mod" >&2; exit 1; }
grep -q 'internal\.Version' "$S" \
  || { echo "docker_compose_test: internal.Version stamp absent" >&2; exit 1; }
echo "docker_compose_test: OK"
