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

# New VMs suspend hard: a soft suspend runs the guest's VMware Tools network script, which flushes
# every interface's address and can't restore it on boot2docker, so the VM resumes unreachable
# (spike, 2026-11-24). Suspend itself stays allowed: VMware hot-adds memory and CPUs by a
# suspend-and-resume. Stock 0.16.2's template says soft; some patch must make it hard.
_p=$(grep -l '^+powerType\.suspend = "hard"$' "$ROOT"/components/docker-machine/patches/*.patch || true)
[ -n "$_p" ] || fail "no patch makes the vmwarefusion .vmx template suspend hard"
grep -q '^-powerType\.suspend = "soft"$' $_p || fail "the patch must replace the template's soft suspend, not add a second line"
grep -q '^+++ b/drivers/vmwarefusion/vmx_darwin.go' $_p || fail "the suspend patch must target drivers/vmwarefusion/vmx_darwin.go"
grep -l '^+suspend\.disabled' "$ROOT"/components/docker-machine/patches/*.patch && fail "no patch may disable suspend: hot-add needs it"
# New VMs allow CPU hot-add (upstream's template already has mem.hotadd), so ctl resize can grow them live.
_p=$(grep -l '^+vcpu\.hotadd = "TRUE"$' "$ROOT"/components/docker-machine/patches/*.patch || true)
[ -n "$_p" ] || fail "no patch adds vcpu.hotadd = \"TRUE\" to the vmwarefusion .vmx template"
grep -q '^+++ b/drivers/vmwarefusion/vmx_darwin.go' $_p || fail "the vcpu.hotadd patch must target drivers/vmwarefusion/vmx_darwin.go"
echo "docker_machine_patches_test: OK"
