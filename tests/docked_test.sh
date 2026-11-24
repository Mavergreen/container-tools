#!/bin/sh
# platform: host-agnostic
# docked IMAGE CMD... behaves exactly like the familiar
#   docker run --rm -i [-t] --network host -v "$PWD":/work -w /work IMAGE CMD...
# after making sure Docker is ready (docker-machine-ctl ensure-ready, when the managed .pkg is
# installed; the standalone archive has no ctl and uses the user's own docker environment).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DOCKED="$ROOT/payload/docked"
fail() { echo "docked_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/docked_test.XXXXXX"); WORK=$(cd "$WORK" && pwd -P)
  BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/here"
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/docker.args"\n' "$WORK" > "$BIN/docker"
  chmod +x "$BIN/docker"
  export MAVERICKS_DOCKER_SHARED_ROOT="$WORK"   # stands in for /Users, the folder Fusion shares
}
stub_ctl() { # $1 = word ensure-ready prints, $2 = its exit code
  printf '#!/bin/sh\necho "$*" >> "%s/ctl.args"\necho %s\nexit %s\n' "$WORK" "$1" "$2" > "$BIN/docker-machine-ctl"
  chmod +x "$BIN/docker-machine-ctl"
}
run() { ( cd "$WORK/here" && PATH="$BIN:/usr/bin:/bin" sh "$DOCKED" "$@" ) < /dev/null > "$WORK/out" 2> "$WORK/err"; }
teardown() { rm -rf "$WORK"; }

case_managed_ready() {
  setup; stub_ctl ready 0
  run alpine ls -l || fail "a ready Docker must run (err: $(cat "$WORK/err"))"
  grep -q '^ensure-ready$' "$WORK/ctl.args" || fail "must ask ctl ensure-ready, not start (got: $(cat "$WORK/ctl.args"))"
  _want=$(printf '%s\n' --context mavericks run --rm -i --network host -v "$WORK/here:/work" -w /work alpine ls -l)
  [ "$(cat "$WORK/docker.args")" = "$_want" ] || fail "docker args: got
$(cat "$WORK/docker.args")
want
$_want"
  [ -s "$WORK/err" ] && fail "nothing to warn about inside the shared folder (got: $(cat "$WORK/err"))"
  teardown
}

case_managed_not_ready() {
  setup; stub_ctl stopped 1
  run alpine true && fail "docked must fail when Docker isn't ready"
  [ -e "$WORK/docker.args" ] && fail "docker must not run when Docker isn't ready"
  grep -qi 'stopped' "$WORK/err" || fail "must say why (got: $(cat "$WORK/err"))"
  teardown
}

case_standalone_no_ctl() {
  setup
  run alpine true || fail "without ctl (standalone) docked still runs (err: $(cat "$WORK/err"))"
  grep -q -- '--context' "$WORK/docker.args" && fail "standalone uses the user's own docker environment, no --context"
  grep -q '^-w$' "$WORK/docker.args" || fail "standalone still starts in /work"
  teardown
}

case_outside_shared_folder() {
  setup; stub_ctl ready 0
  MAVERICKS_DOCKER_SHARED_ROOT=/nonexistent-shared-root run alpine true || fail "outside the shared folder still runs"
  grep -q 'nonexistent-shared-root' "$WORK/err" || fail "must warn that the VM can't see this folder (got: $(cat "$WORK/err"))"
  teardown
}

case_no_image() {
  setup; stub_ctl ready 0
  run && fail "docked with no image must fail with usage"
  grep -qi 'usage' "$WORK/err" || fail "must print usage (got: $(cat "$WORK/err"))"
  teardown
}

case_managed_ready
case_managed_not_ready
case_standalone_no_ctl
case_outside_shared_folder
case_no_image
echo "docked_test: OK"
