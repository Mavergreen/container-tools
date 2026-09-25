#!/bin/sh
# platform: host-agnostic
# Unit tests for docker-machine-common.sh helpers via PATH stubs.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMMON="$ROOT/payload/docker-machine-common.sh"
[ -f "$COMMON" ] || { echo "docker_common_test: common missing" >&2; exit 1; }
fail() { echo "docker_common_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-common.XXXXXX")
  BIN="$WORK/bin"; mkdir -p "$BIN"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state"
  export MAVERICKS_DOCKER_LOG="$WORK/log"
  export MAVERICKS_DOCKER_FUSION_PRESENT=1
  OLDPATH=$PATH; PATH="$BIN:$PATH"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }
stub_dm() { # $1 = status word the stub echoes ("" => exit 1)
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
[ "\$1" = status ] && { [ -n "$1" ] && { echo "$1"; exit 0; }; exit 1; }
EOF
  chmod +x "$BIN/docker-machine"
}

case_status_word() {
  setup; stub_dm Running
  ( . "$COMMON"; [ "$(status_word)" = running ] ) || fail "Running -> running"
  stub_dm Stopped
  ( . "$COMMON"; [ "$(status_word)" = stopped ] ) || fail "Stopped -> stopped"
  stub_dm ""   # absent
  ( . "$COMMON"; [ "$(status_word)" = absent ] ) || fail "empty -> absent"
  ( MAVERICKS_DOCKER_FUSION_PRESENT=0; . "$COMMON"; [ "$(status_word)" = no-fusion ] ) || fail "no fusion -> no-fusion"
  teardown
}

case_creating() {
  setup; stub_dm Stopped
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/creating.lock"   # fresh lock
  ( . "$COMMON"; [ "$(status_word)" = creating ] ) || fail "fresh lock -> creating"
  teardown
}

case_write_state() {
  setup
  ( . "$COMMON"; write_state running )
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state")" = running ] || fail "write_state must write the word"
  teardown
}

case_bindir_on_path() {
  # A GUI caller (the menu-bar app, launched by LaunchServices) gets a PATH without the install
  # bindir, so a bare `docker-machine` fails to resolve and status_word silently reports "absent"
  # while the VM is really Stopped (start/stop likewise no-op). common.sh must guarantee the
  # install bindir is reachable regardless of the caller's PATH. Regression: dogfooding 2026-07-29.
  setup
  GUIBIN="$WORK/guibin"; mkdir -p "$GUIBIN"
  cat > "$GUIBIN/docker-machine" <<'EOF'
#!/bin/sh
[ "$1" = status ] && { echo Stopped; exit 0; }
EOF
  chmod +x "$GUIBIN/docker-machine"
  ( export MAVERICKS_DOCKER_BINDIR="$GUIBIN"; PATH="/usr/bin:/bin"
    . "$COMMON"; [ "$(status_word)" = stopped ] ) \
    || fail "GUI PATH (no bindir): common.sh must add MAVERICKS_DOCKER_BINDIR so docker-machine resolves"
  teardown
}

# image_status compares the VM's booted ISO to the freshly-installed one; repoint_iso_url fixes a
# migrated host's stale Boot2DockerURL. Both are CLI-usable (no GUI).
case_image_status() {
  setup
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"; mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  export MAVERICKS_DOCKER_ISO="$WORK/installed.iso"; printf 'NEW\n' > "$MAVERICKS_DOCKER_ISO"
  _m="$MAVERICKS_DOCKER_MACHDIR/container-tools/boot2docker.iso"
  ( . "$COMMON"; [ "$(image_status)" = absent ] )  || fail "no machine iso -> absent"
  cp "$MAVERICKS_DOCKER_ISO" "$_m"
  ( . "$COMMON"; [ "$(image_status)" = current ] ) || fail "matching iso -> current"
  printf 'OLD\n' > "$_m"
  ( . "$COMMON"; [ "$(image_status)" = stale ] )   || fail "differing iso -> stale"
  printf '{ "Boot2DockerURL": "/Volumes/Old/boot2docker.iso" }\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json"
  ( . "$COMMON"; repoint_iso_url )
  grep -q "\"Boot2DockerURL\": \"$MAVERICKS_DOCKER_ISO\"" "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json" \
    || fail "repoint_iso_url must set Boot2DockerURL to the installed ISO"
  teardown
}

# op.lock: a generic in-progress marker for the ctl verbs (start/stop/restart/image-upgrade).
# op_begin writes working:<op> + creates the lock; op_end removes it and settles the state.
# (status_word's working:<op> branch and stale-reclaim are covered in case_op_lock_status, Task 2.)
case_op_lock() {
  setup; stub_dm Running
  ( . "$COMMON"; op_begin image-upgrade )
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state")" = "working:image-upgrade" ] \
    || fail "op_begin must write working:<op> to the state file"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] || fail "op_begin must create op.lock"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name")" = image-upgrade ] \
    || fail "op_begin must record the op name"
  ( . "$COMMON"; op_end )
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "op_end must remove op.lock"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state")" = running ] \
    || fail "op_end must write the real status back"
  teardown
}

# status_word must surface a fresh op.lock as working:<op>, after the create_in_progress check,
# and must reclaim a stale (>600s) op.lock rather than report it as working.
case_op_lock_status() {
  setup; stub_dm Running
  ( . "$COMMON"; op_begin image-upgrade )
  ( . "$COMMON"; [ "$(status_word)" = "working:image-upgrade" ] ) \
    || fail "status_word must report working:<op> while the lock is fresh"
  touch -t 200001010000 "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  ( . "$COMMON"; [ "$(status_word)" = running ] ) \
    || fail "a stale op.lock must be reclaimed, not reported as working"
  teardown
}

case_status_word
case_creating
case_write_state
case_bindir_on_path
case_image_status
case_op_lock
case_op_lock_status
echo "docker_common_test: OK"
