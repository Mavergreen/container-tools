#!/bin/sh
# platform: host-agnostic
# build_docker_machine.sh applies components/docker-machine/patches with shipyard's apply_patches.sh
# before building, and stops if they don't apply: 0001 is what lets `docker-machine create` survive
# Fusion 8.5's guest-side shared-folder mount failing (2026-11-22), so a build without it must fail
# rather than ship a docker-machine whose every create aborts before provisioning.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/docker_machine_patches_test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "docker_machine_patches_test: FAIL: $*" >&2; exit 1; }

ls "$ROOT"/components/docker-machine/patches/*.patch >/dev/null 2>&1 || fail "no docker-machine patch overlay"
mkdir -p "$T/src"
printf '#!/bin/sh\necho "go $1" >> "%s/log"\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { : > "$2"; exit 0; }; shift; done\n' "$T" > "$T/go"
printf '#!/bin/sh\necho "apply $1 $2" >> "%s/log"\nexit ${APPLY_RC:-0}\n' "$T" > "$T/apply"
chmod +x "$T/go" "$T/apply"

sh "$ROOT/cmake/build_docker_machine.sh" "$T/src" "$T/out" "$T/go" "$T/gopath" "$T/apply" >/dev/null 2>&1 \
  || fail "build with a clean apply should succeed"
[ "$(head -1 "$T/log")" = "apply $T/src $ROOT/components/docker-machine/patches" ] \
  || fail "the overlay must be applied to SRC first (got: $(cat "$T/log"))"
grep -q '^go build' "$T/log" || fail "then built"

: > "$T/log"; rm -rf "$T/out"
APPLY_RC=1 sh "$ROOT/cmake/build_docker_machine.sh" "$T/src" "$T/out" "$T/go" "$T/gopath" "$T/apply" >/dev/null 2>&1 \
  && fail "a patch that doesn't apply must fail the build"
grep -q '^go build' "$T/log" && fail "nothing may be built when the overlay doesn't apply"

# New VMs are created with suspend off, as every VM that ran in production was (Wowfunhappy's
# docker-machine wrote it; stock 0.16.2 doesn't): some patch adds it to the driver's .vmx template.
_p=$(grep -l '^+suspend\.disabled = "TRUE"$' "$ROOT"/components/docker-machine/patches/*.patch || true)
[ -n "$_p" ] || fail "no patch adds suspend.disabled = \"TRUE\" to the vmwarefusion .vmx template"
grep -q '^+++ b/drivers/vmwarefusion/vmx_darwin.go' $_p || fail "the suspend patch must target drivers/vmwarefusion/vmx_darwin.go"
echo "docker_machine_patches_test: OK"
