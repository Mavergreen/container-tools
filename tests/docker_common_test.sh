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
  rm -f "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid"   # a lock from before op.lock recorded its owner
  touch -t 200001010000 "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  ( . "$COMMON"; [ "$(status_word)" = running ] ) \
    || fail "a stale op.lock must be reclaimed, not reported as working"
  teardown
}

# op.lock records the pid that holds it, and its liveness -- not the lock's age -- decides whether
# the op is still going. An image-upgrade took 15+ min on 2026-10-24 (VMware had paused the VM for
# host disk space); the old 600s reclaim let the login agent's tick run a concurrent start.
case_op_lock_owner() {
  setup; stub_dm Running
  ( . "$COMMON"; op_begin image-upgrade )   # a subshell keeps $$: this live test shell holds it
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid")" = $$ ] || fail "op_begin must record its pid"
  touch -t 200001010000 "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  ( . "$COMMON"; [ "$(status_word)" = "working:image-upgrade" ] ) \
    || fail "an old op.lock whose owner is alive must still report working"
  sh -c 'exit 0' & _dead=$!; wait $_dead
  printf '%s\n' "$_dead" > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid"
  touch "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  ( . "$COMMON"; [ "$(status_word)" = running ] ) \
    || fail "a fresh op.lock whose owner is gone must be reclaimed"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "reclaiming must remove op.lock"
  teardown
}

# VMware pauses the VM when the host disk fills, and writes a noSpace question to vmware.log every
# second while it waits. docker-machine then flaps between Running and Stopped, so status_word must
# say what is actually wrong -- even mid-op, since the op is stuck on the same pause.
stub_vmx() { # $1 = pid pgrep reports for the VM's vmx ("" => none)
  printf '#!/bin/sh\n[ -n "%s" ] && echo %s\n' "$1" "$1" > "$BIN/pgrep"; chmod +x "$BIN/pgrep"
}
paused_log() {
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"; mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  cat > "$MAVERICKS_DOCKER_MACHDIR/container-tools/vmware.log" <<'LOG'
2026-10-24T14:00:36.284-05:00| vmx| I125: Msg_Question:
2026-10-24T14:00:36.284-05:00| vmx| I125: [msg.mainMemPosix.noSpaceCritical] The file system upon which '/x' resides is critically low on free space.
2026-10-24T14:00:36.284-05:00| vmx| I125: [msg.mainMemPosix.noSpaceBasic] vmrun has paused this virtual machine because the disk on which the virtual machine is stored is almost full.
2026-10-24T14:00:36.284-05:00| vmx| I125: ----------------------------------------
2026-10-24T14:00:36.284-05:00| vmx| I125: MsgIsAnswered: Using builtin default 'Continue' as the answer for 'msg.mainMemPosix.noSpaceBasic'
2026-10-24T14:00:36.284-05:00| vmx| I125: MsgQuestion: msg.mainMemPosix.noSpaceBasic reply=0
LOG
}
case_host_disk_full() {
  setup; stub_dm Running; stub_vmx 4242; paused_log
  ( . "$COMMON"; [ "$(status_word)" = host-disk-full ] ) || fail "a paused-for-space VM -> host-disk-full"
  ( . "$COMMON"; op_begin image-upgrade; [ "$(status_word)" = host-disk-full ] ) \
    || fail "host-disk-full must win over working:<op>"
  rm -rf "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  touch -t 200001010000 "$MAVERICKS_DOCKER_MACHDIR/container-tools/vmware.log"
  ( . "$COMMON"; [ "$(status_word)" = running ] ) || fail "a quiet log (the VM resumed) is not paused"
  touch "$MAVERICKS_DOCKER_MACHDIR/container-tools/vmware.log"; stub_vmx ""
  ( . "$COMMON"; [ "$(status_word)" = running ] ) || fail "no vmx process -> not paused"
  teardown
}

# Fusion backs guest RAM with a memsize-sized .vmem file, allocated in full at every power-on (on
# Fusion 8.5 for Mac, mainMem.useNamedFile = "FALSE" is read and ignored -- tried 2026-10-24). So
# powering on needs memsize of free space plus headroom, or VMware pauses the VM for space.
stub_df() { # $1 = KB available where the VM lives
  printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/disk0s2 1 1 %s 99%% /"\n' "$1" \
    > "$BIN/df"; chmod +x "$BIN/df"
}
case_host_room_to_boot() {
  setup
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"; mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "16384"\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  stub_df 31457280   # 30 GB
  ( . "$COMMON"; host_room_to_boot ) || fail "30 GB free is room for a 16 GB VM"
  stub_df 18874368   # 18 GB: the .vmem fits, the headroom doesn't
  ( . "$COMMON"; host_room_to_boot ) && fail "18 GB free is not room for a 16 GB VM plus headroom"
  rm -f "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  ( . "$COMMON"; host_room_to_boot ) || fail "no vmx to read memsize from must not block a start"
  teardown
}

case_status_word
case_creating
case_write_state
case_bindir_on_path
case_image_status
case_op_lock
case_op_lock_status
case_op_lock_owner
case_host_disk_full
case_host_room_to_boot
echo "docker_common_test: OK"
