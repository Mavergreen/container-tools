#!/bin/sh
# platform: host-agnostic
# autosize_tick: what the login agent does about the VM's size each minute -- sample the guest, ask
# autosize_decide, and grow live, or hold a restart change until no container runs (or the next
# start). It never stops a running container (design, 2026-11-24).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOOT="$ROOT/payload/docker-machine-bootstrap"
fail() { echo "autosize_tick_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/autosize-tick.XXXXXX")
  BIN="$WORK/bin"; G="$WORK/guest"; mkdir -p "$BIN" "$G"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state"; mkdir -p "$MAVERICKS_DOCKER_STATE_DIR"
  export MAVERICKS_DOCKER_LOG="$WORK/log"
  export MAVERICKS_DOCKER_FUSION_PRESENT=1
  export MAVERICKS_DOCKER_COMMON="$ROOT/payload/docker-machine-common.sh"
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"
  export MAVERICKS_DOCKER_HOTPLUG="$BIN/hotplug"
  export MAVERICKS_DOCKER_BOOT_ID=boot-1
  export MAVERICKS_DOCKER_NONINTERACTIVE=1
  export MAVERICKS_DOCKER_PROFILES="$WORK/none"
  export MAVERICKS_DOCKER_RESIZE_WAIT=3
  export MAVERICKS_DOCKER_NOW=1000000
  ST="$MAVERICKS_DOCKER_STATE_DIR"
  : > "$ST/autosize-decided"   # the first-run decision is made (cases that test it remove this)
  VMX="$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"; mkdir -p "$(dirname "$VMX")"
  printf 'memsize = "1024"\nnumvcpus = "1"\npowerType.suspend = "hard"\nmem.hotadd = "TRUE"\nvcpu.hotadd = "TRUE"\n' > "$VMX"
  boot_log 1024
  echo Running > "$G/status"; : > "$G/marker"; : > "$G/calls"; : > "$G/notes"
  echo 962560 > "$G/memkb"; echo 1 > "$G/cpus"
  sample 0 0 962560 700000 0.10
  # docker-machine: status from a file; stop/start flip it; ssh serves the sample, the marker and sizes.
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
echo "dm \$*" >> "$G/calls"
case "\$1" in
  status) cat "$G/status" ;;
  stop)   echo Stopped > "$G/status" ;;
  start)  echo Running > "$G/status" ;;
  ssh)    shift 2
          case "\$*" in
            *vmstat*) [ -e "$G/ssh-fails" ] && exit 255; cat "$G/sample" ;;
            *99-mavergreen-cpu-online.rules*) [ -e "$G/marker" ] ;;
            *meminfo*) cat "$G/memkb"; cat "$G/cpus" ;;
            *) exit 0 ;;
          esac ;;
  env)    exit 1 ;;
  *)      exit 0 ;;
esac
EOF
  cat > "$BIN/hotplug" <<EOF
#!/bin/sh
echo "hotplug \$2 \$3" >> "$G/calls"
case "\$2" in
  --memory) sed "s/^memsize = .*/memsize = \"\$3\"/" "$VMX" > "$VMX.t" && cat "$VMX.t" > "$VMX"; echo \$(( \$3 * 940 )) > "$G/memkb" ;;
  --cpus)   sed "s/^numvcpus = .*/numvcpus = \"\$3\"/" "$VMX" > "$VMX.t" && cat "$VMX.t" > "$VMX"; echo \$3 > "$G/cpus" ;;
esac
EOF
  cat > "$BIN/pgrep" <<EOF
#!/bin/sh
[ "\$(cat "$G/status")" = Running ] && echo 4242 || exit 1
EOF
  cat > "$BIN/sysctl" <<'EOF'
#!/bin/sh
case "$*" in *hw.memsize*) echo 17179869184 ;; *hw.logicalcpu*) echo 4 ;; *) echo boot-1 ;; esac
EOF
  cat > "$BIN/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/disk0s2 487000000 1 104857600 50% /"
EOF
  cat > "$BIN/docker" <<EOF
#!/bin/sh
case "\$*" in *" ps -q"*) [ -e "$G/docker-down" ] && exit 1; cat "$G/containers" 2>/dev/null ;; esac
exit 0
EOF
  cat > "$BIN/osascript" <<EOF
#!/bin/sh
echo "\$*" >> "$G/notes"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$BIN/notifyutil"; printf '#!/bin/sh\nexit 0\n' > "$BIN/launchctl"
  chmod +x "$BIN"/*
  OLDPATH=$PATH; PATH="$BIN:$PATH"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }
# What the guest reports: oom_kill pswpin MemTotal MemAvailable load5 [psi-mem psi-cpu]
sample() {
  { echo "oom_kill $1"; echo "pswpin $2"; echo "MemTotal:  $3 kB"; echo "MemAvailable:  $4 kB"
    echo "loadavg 0.00 $5 0.00 1/100 1"
    [ -z "${6:-}" ] || echo "psi_memory avg10=0.00 avg60=$6 avg300=0.00 total=0"
    [ -z "${7:-}" ] || echo "psi_cpu avg10=0.00 avg60=$7 avg300=0.00 total=0"; } > "$G/sample"
}
boot_log() { printf '2026-11-24T10:00:00.000-05:00| vmx| I125: DICT                memsize = "%s"\n' "$1" > "$(dirname "$VMX")/vmware.log"; }
set_vmx() { sed -e "s/^memsize = .*/memsize = \"$1\"/" -e "s/^numvcpus = .*/numvcpus = \"$2\"/" "$VMX" > "$VMX.t" && cat "$VMX.t" > "$VMX"; }
vmx_size() { echo "$(sed -n 's/^memsize = "\(.*\)"/\1/p' "$VMX")/$(sed -n 's/^numvcpus = "\(.*\)"/\1/p' "$VMX")"; }
tick() { MAVERICKS_DOCKER_NOW=$(( MAVERICKS_DOCKER_NOW + 60 )); ( . "$MAVERICKS_DOCKER_COMMON"; autosize_tick ) >>"$WORK/out" 2>&1 || true; }
ssh_calls() { grep -c '^dm ssh' "$G/calls" || true; }

case_off_does_nothing() {
  setup; : > "$ST/autosize-off"; sample 1 0 962560 700000 0.10
  tick; tick
  [ "$(ssh_calls)" = 0 ] || fail "self-sizing off: no sampling ($(cat "$G/calls"))"
  teardown
}
case_op_in_progress_does_nothing() {
  setup; mkdir "$ST/op.lock"; echo $$ > "$ST/op.lock/pid"
  tick
  [ "$(ssh_calls)" = 0 ] || fail "an op in progress: no sampling"
  teardown
}
case_paused_for_disk_does_nothing() {
  setup; printf '%s.000-05:00| vmx| I125: Msg_Question: msg.hbacommon.outofspace\n' "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$(dirname "$VMX")/vmware.log"
  tick
  [ "$(ssh_calls)" = 0 ] || fail "VM paused for host disk: no sampling"
  teardown
}
case_stopped_vm_does_nothing() {
  setup; echo Stopped > "$G/status"
  tick
  [ "$(ssh_calls)" = 0 ] || fail "a stopped VM isn't sampled"
  teardown
}
case_oom_grows_live() {
  setup; tick; sample 1 0 962560 700000 0.10; tick
  grep -q '^hotplug --memory 2048' "$G/calls" || fail "an OOM kill grows memory live ($(cat "$G/calls"); $(cat "$WORK/out"))"
  [ "$(vmx_size)" = 2048/1 ] || fail "the VM is now 2048/1 (got $(vmx_size))"
  grep -q '^dm stop' "$G/calls" && fail "a live grow stops nothing"
  grep -q 'autosize' "$WORK/log" || fail "the decision is logged"
  teardown
}
case_restart_change_waits_while_containers_run() {
  setup; set_vmx 3072 1; echo abc123 > "$G/containers"; tick; sample 1 0 2887680 100000 0.10; tick
  [ "$(cat "$ST/autosize-pending" 2>/dev/null)" = "6144 1" ] || fail "a grow past the live cap is held (pending: $(cat "$ST/autosize-pending" 2>/dev/null))"
  grep -q '^dm stop' "$G/calls" && fail "never stops a running container"
  [ "$(vmx_size)" = 3072/1 ] || fail "unchanged while containers run"
  teardown
}
case_restart_change_applies_when_idle() {
  setup; set_vmx 3072 1; echo abc123 > "$G/containers"; tick; sample 1 0 2887680 100000 0.10; tick
  rm -f "$G/containers"; tick
  [ "$(vmx_size)" = 6144/1 ] || fail "with nothing running, the held change applies (got $(vmx_size); $(cat "$WORK/out"))"
  grep -q '^dm stop' "$G/calls" && grep -q '^dm start' "$G/calls" || fail "by a restart"
  [ -e "$ST/autosize-pending" ] && fail "and is no longer pending"
  teardown
}
case_docker_down_is_not_idle() {
  setup; set_vmx 3072 1; echo abc123 > "$G/containers"; tick; sample 1 0 2887680 100000 0.10; tick
  rm -f "$G/containers"; : > "$G/docker-down"; tick
  grep -q '^dm stop' "$G/calls" && fail "an unanswered docker ps is not 'nothing running'"
  [ "$(vmx_size)" = 3072/1 ] || fail "unchanged"
  teardown
}
case_pending_grow_notifies() {
  setup; set_vmx 3072 1; echo abc123 > "$G/containers"; tick; sample 1 0 2887680 100000 0.10; tick
  sample 2 0 2887680 100000 0.10; tick
  grep -q 'when no containers are running' "$G/notes" || fail "pressure with a grow held says so ($(cat "$G/notes"))"
  sample 3 0 2887680 100000 0.10; tick
  [ "$(grep -c 'when no containers are running' "$G/notes")" = 1 ] || fail "once a day"
  teardown
}
case_pending_shrink_dropped_on_pressure() {
  setup; set_vmx 4096 2; boot_log 4096; echo abc123 > "$G/containers"; echo "2048 1" > "$ST/autosize-pending"
  tick; sample 1 0 3850000 100000 0.10; tick
  [ -e "$ST/autosize-pending" ] && [ "$(cat "$ST/autosize-pending")" = "2048 1" ] && fail "pressure drops a held shrink"
  teardown
}
case_pending_grow_dropped_when_reached() {
  setup; set_vmx 6144 1; boot_log 6144; echo "4096 1" > "$ST/autosize-pending"; echo abc123 > "$G/containers"
  tick
  [ -e "$ST/autosize-pending" ] && fail "a held grow the VM already reached is dropped"
  teardown
}
case_ceiling_notifies_once_a_day() {
  setup; set_vmx 8192 3; boot_log 8192; tick
  sample 1 0 7700000 100000 0.10; tick; sample 2 0 7700000 100000 0.10; tick
  grep -q '^hotplug' "$G/calls" && fail "at the ceiling, no resize"
  [ "$(grep -c 'more memory than self-sizing' "$G/notes")" = 1 ] || fail "one ceiling notice a day ($(cat "$G/notes"))"
  teardown
}
case_failed_sample_no_change() {
  setup; tick; cp "$ST/autosize-state" "$WORK/before"; : > "$G/ssh-fails"; sample 1 0 962560 700000 0.10; tick
  cmp -s "$ST/autosize-state" "$WORK/before" || fail "a failed sample changes nothing"
  grep -q '^hotplug' "$G/calls" && fail "and resizes nothing"
  teardown
}
case_pending_applied_at_next_start() {
  setup; echo Stopped > "$G/status"; echo "2048 1" > "$ST/autosize-pending"
  sh "$BOOT" >/dev/null 2>&1 || true
  [ "$(vmx_size)" = 2048/1 ] || fail "a held change applies when the VM next starts (got $(vmx_size); $(tail -5 "$WORK/log"))"
  [ "$(cat "$G/status")" = Running ] || fail "and the VM is up"
  [ -e "$ST/autosize-pending" ] && fail "and is no longer pending"
  teardown
}
case_user_stopped_not_started() {
  setup; echo Stopped > "$G/status"; echo "2048 1" > "$ST/autosize-pending"; echo boot-1 > "$ST/user-stopped"
  sh "$BOOT" >/dev/null 2>&1 || true
  grep -q '^dm start' "$G/calls" && fail "a VM the user stopped stays stopped"
  [ "$(vmx_size)" = 1024/1 ] || fail "and its size waits"
  teardown
}

CTL="$ROOT/payload/docker-machine-ctl"
ctl() { sh "$CTL" "$@" > "$WORK/ctl-out" 2>&1; }
# Existing VMs (maintainer's decision): on if at the default size, off if someone enlarged it; once.
case_first_decision_default_size_on() {
  setup; rm -f "$ST/autosize-decided"; tick
  [ -e "$ST/autosize-decided" ] || fail "the first tick decides"
  [ -e "$ST/autosize-off" ] && fail "a VM at 1024/1 self-sizes"
  [ "$(ssh_calls)" -ge 1 ] || fail "and samples on that tick"
  teardown
}
case_first_decision_enlarged_off() {
  setup; rm -f "$ST/autosize-decided"; set_vmx 16384 6; tick
  [ -e "$ST/autosize-off" ] || fail "an enlarged VM keeps its size: self-sizing off"
  [ "$(ssh_calls)" = 0 ] || fail "and nothing is sampled"
  teardown
}
case_first_decision_once() {
  setup; rm -f "$ST/autosize-decided"; tick; set_vmx 16384 6; tick
  [ -e "$ST/autosize-off" ] && fail "the decision is made once, not again when the size changes"
  teardown
}
case_autosize_verbs() {
  setup; : > "$ST/autosize-decided"; echo "2048 1" > "$ST/autosize-pending"
  ctl autosize status; grep -qx on "$WORK/ctl-out" && grep -q 'pending 2048 1' "$WORK/ctl-out" || fail "status says on and what's held ($(cat "$WORK/ctl-out"))"
  ctl autosize off; [ -e "$ST/autosize-off" ] && [ ! -e "$ST/autosize-pending" ] || fail "off pins and drops what's held"
  ctl autosize status; grep -qx off "$WORK/ctl-out" || fail "status says off"
  ctl autosize on; [ ! -e "$ST/autosize-off" ] || fail "on turns it back on"
  ctl autosize bogus && fail "a bad word is refused"
  teardown
}
case_user_resize_pins_and_clears_pending() {
  setup; : > "$ST/autosize-decided"; echo "6144 1" > "$ST/autosize-pending"
  ctl resize --memory 2048 || fail "the user's resize works ($(cat "$WORK/ctl-out"))"
  [ -e "$ST/autosize-off" ] || fail "the user's resize pins the size"
  [ -e "$ST/autosize-pending" ] && fail "and drops what self-sizing held"
  grep -q 'autosize on' "$WORK/ctl-out" || fail "and says how to turn self-sizing back on ($(cat "$WORK/ctl-out"))"
  : > "$G/calls"; sample 9 0 962560 700000 0.10; tick
  [ "$(ssh_calls)" = 0 ] || fail "the next tick leaves a pinned VM alone"
  teardown
}
case_failed_user_resize_doesnt_pin() {
  setup; : > "$ST/autosize-decided"
  ctl resize --memory 999 && fail "999 isn't a multiple of 4"
  [ -e "$ST/autosize-off" ] && fail "a refused resize changes nothing, so it doesn't pin"
  teardown
}
case_overview_lines() {
  setup; : > "$ST/autosize-decided"; echo "6144 1" > "$ST/autosize-pending"
  ctl overview-status; grep -qx 'autosize on' "$WORK/ctl-out" && grep -qx 'autosize-pending 6144 1' "$WORK/ctl-out" \
    || fail "the overview says on and what's held ($(cat "$WORK/ctl-out"))"
  : > "$ST/autosize-off"; rm -f "$ST/autosize-pending"; ctl overview-status
  grep -qx 'autosize off' "$WORK/ctl-out" && ! grep -q autosize-pending "$WORK/ctl-out" || fail "and off ($(cat "$WORK/ctl-out"))"
  teardown
}

case_off_does_nothing
case_op_in_progress_does_nothing
case_paused_for_disk_does_nothing
case_stopped_vm_does_nothing
case_oom_grows_live
case_restart_change_waits_while_containers_run
case_restart_change_applies_when_idle
case_docker_down_is_not_idle
case_pending_grow_notifies
case_pending_shrink_dropped_on_pressure
case_pending_grow_dropped_when_reached
case_ceiling_notifies_once_a_day
case_failed_sample_no_change
case_pending_applied_at_next_start
case_user_stopped_not_started
case_first_decision_default_size_on
case_first_decision_enlarged_off
case_first_decision_once
case_autosize_verbs
case_user_resize_pins_and_clears_pending
case_failed_user_resize_doesnt_pin
case_overview_lines
echo "autosize_tick_test: OK"
