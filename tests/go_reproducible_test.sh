#!/bin/sh
# platform: host-agnostic
# Every Go component builds reproducibly across hosts: -trimpath on the `go build` (Go stamps host paths
# otherwise), and cgo's C debug paths mapped with -ffile-prefix-map under both spellings of the work dir.
# spec: shipyard's coming conformance check (every Go binary in a pkg is built -trimpath; found in tailscale).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail=0
for s in build_docker_cli build_docker_compose build_docker_machine build_lazydocker; do
  f="$ROOT/cmake/$s.sh"
  grep -q '"\$GO" build -trimpath' "$f" || { echo "go_reproducible_test: FAIL: $s.sh's go build lacks -trimpath" >&2; fail=1; }
  grep -q 'ffile-prefix-map=\$PWD=' "$f" && grep -q 'ffile-prefix-map=\$(pwd -P)=' "$f" \
    || { echo "go_reproducible_test: FAIL: $s.sh doesn't map cgo debug paths for both \$PWD and \$(pwd -P)" >&2; fail=1; }
done
[ "$fail" -eq 0 ] || exit 1
echo "go_reproducible_test: OK"
