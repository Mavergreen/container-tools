#!/bin/sh
# platform: host-agnostic
# docker-machine-ctl resize [--memory MB] [--cpus N] [--restart]: grows the running VM live through
# VMware's hot-add (libexec/container-tools-hotplug) when it can, and makes any other change (a
# shrink, a VM not yet ready to hot-add, a stopped VM) only by a restart, only when told --restart:
# a restart stops running containers (design, 2026-11-24).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CTL="$ROOT/payload/docker-machine-ctl"
fail() { echo "docker_resize_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-resize.XXXXXX")
  BIN="$WORK/bin"; G="$WORK/guest"; mkdir -p "$BIN" "$G"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state"
  export MAVERICKS_DOCKER_LOG="$WORK/log"
  export MAVERICKS_DOCKER_FUSION_PRESENT=1
  export MAVERICKS_DOCKER_COMMON="$ROOT/payload/docker-machine-common.sh"
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"
  export MAVERICKS_DOCKER_HOTPLUG="$BIN/hotplug"
  export MAVERICKS_DOCKER_BOOT_ID=boot-1
  VMX="$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"; mkdir -p "$(dirname "$VMX")"
  printf 'memsize = "1024"\nnumvcpus = "1"\npowerType.suspend = "hard"\nmem.hotadd = "TRUE"\nvcpu.hotadd = "TRUE"\n' > "$VMX"
  echo Running > "$G/status"; : > "$G/marker"      # the guest booted a kernel that can take a hot-add
  echo 962560 > "$G/memkb"; echo 1 > "$G/cpus"     # what the guest reports (MemTotal is ~94% of memsize)
  echo 0 > "$G/hotplug-rc"; echo 104857600 > "$G/avail-kb"   # 100 GB free
  : > "$G/calls"
  # docker-machine: status from the file; stop/start flip it; ssh answers the marker and size reads.
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
echo "dm \$*" >> "$G/calls"
case "\$1" in
  status) cat "$G/status" ;;
  stop)   echo Stopped > "$G/status"; rm -f "$G/vmx-alive" ;;
  start)  echo Running > "$G/status" ;;
  ssh)    shift 2
          case "\$*" in
            *99-mavergreen-cpu-online.rules*) [ -e "$G/marker" ] ;;
            *meminfo*) cat "$G/memkb"; cat "$G/cpus" ;;
            *) exit 0 ;;
          esac ;;
  env)    exit 1 ;;
  *)      exit 0 ;;
esac
EOF
  # The helper does what Fusion does: rewrites the vmx's size, and the guest then shows it.
  cat > "$BIN/hotplug" <<EOF
#!/bin/sh
echo "hotplug \$2 \$3" >> "$G/calls"
rc=\$(cat "$G/hotplug-rc"); [ "\$rc" = 0 ] || { echo "container-tools-hotplug: hotplug: 13 The operation is not supported" >&2; exit \$rc; }
[ -e "$G/lazy" ] && exit 0
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
  cat > "$BIN/df" <<EOF
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/disk0s2 487000000 1 \$(cat "$G/avail-kb") 50% /"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$BIN/docker"; printf '#!/bin/sh\nexit 0\n' > "$BIN/notifyutil"
  chmod +x "$BIN"/*
  OLDPATH=$PATH; PATH="$BIN:$PATH"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }
run() { sh "$CTL" resize "$@" > "$WORK/out" 2>&1; }
out() { cat "$WORK/out"; }
no_change_calls() { ! grep -q -e '^hotplug' -e '^dm stop' -e '^dm start' "$G/calls"; }
vmx_size() { echo "$(sed -n 's/^memsize = "\(.*\)"/\1/p' "$VMX")/$(sed -n 's/^numvcpus = "\(.*\)"/\1/p' "$VMX")"; }

# Fusion grows a VM that booted with less than 3 GB only up to 3 GB live ("Requested memory size
# 6144MB is greater than allowed maximum of 3072MB"); one booted at 4 GB grew live to 16 GB (2026-11-24).
# vmware.log's DICT memsize is the size it booted with.
boot_log() { printf '2026-11-24T13:09:51.200-05:00| vmx| I125: DICT                   memsize = "%s"\n' "$1" > "$(dirname "$VMX")/vmware.log"; }
case_live_cap_from_small_boot() {
  setup; boot_log 1024
  run --memory 3072 || fail "up to 3 GB grows live from a small boot (out: $(out))"
  grep -q '^hotplug --memory 3072$' "$G/calls" || fail "live (calls: $(cat "$G/calls"))"
  teardown
  setup; boot_log 1024
  run --memory 4096 && fail "past 3 GB from a small boot can't grow live"
  out | grep -q -- --restart && out | grep -q '3 GB' || fail "says why and names --restart (out: $(out))"
  no_change_calls || fail "changes nothing"
  run --memory 4096 --restart || fail "with --restart it goes (out: $(out))"
  grep -q '^hotplug' "$G/calls" && fail "by restart, not hot-add"
  [ "$(vmx_size)" = 4096/1 ] || fail "size written (got $(vmx_size))"
  teardown
  setup; boot_log 4096; sed 's/^memsize = .*/memsize = "4096"/' "$VMX" > "$VMX.t" && cat "$VMX.t" > "$VMX"
  run --memory 8192 || fail "a VM that booted at 4 GB grows live past it (out: $(out))"
  grep -q '^hotplug --memory 8192$' "$G/calls" || fail "live (calls: $(cat "$G/calls"))"
  teardown
}

# Review fixes (2026-11-24).
# I-1: VMware paused the VM for host disk (docker-machine status flaps, ssh hangs): refuse up front.
#      And "running" is the vmx process, never docker-machine's flapping status: never write a live VM's vmx.
case_paused_for_host_disk() {
  setup
  printf '%s.000-05:00| vmx| I125: Msg_Question: msg.hbacommon.outofspace\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "$(dirname "$VMX")/vmware.log"
  run --memory 2048 --restart && fail "a VM paused for host disk can't be resized"
  out | grep -qi 'disk' || fail "says the Mac's disk is full (out: $(out))"
  no_change_calls || fail "changes nothing"
  [ "$(vmx_size)" = 1024/1 ] || fail "the vmx is untouched (got $(vmx_size))"
  teardown
}
case_status_flaps_but_vmx_alive() {
  setup; : > "$G/vmx-alive"; echo Stopped > "$G/status"   # the vmx is up, but docker-machine says Stopped
  printf '#!/bin/sh\n[ -e "%s/vmx-alive" ] && echo 4242 || exit 1\n' "$G" > "$BIN/pgrep"
  run --memory 512 --restart
  grep -q '^dm stop' "$G/calls" || [ "$(vmx_size)" = 1024/1 ] || fail "a running vmx's .vmx must never be rewritten without stopping it (got $(vmx_size), calls: $(cat "$G/calls"))"
  teardown
}
# I-2: a suspended VM resumes against the vmx it was suspended with: never rewrite it.
case_suspended_vm() {
  setup; echo Stopped > "$G/status"; echo 'checkpoint.vmState = "container-tools-1.vmss"' >> "$VMX"
  run --memory 2048 --restart && fail "a suspended VM can't be resized"
  out | grep -qi suspended || fail "says it's suspended (out: $(out))"
  no_change_calls || fail "changes nothing"
  [ "$(vmx_size)" = 1024/1 ] || fail "the vmx is untouched (got $(vmx_size))"
  teardown
}
# I-3: the marker is missing because the VM boots an old image: a restart won't fix that, an image upgrade will.
case_stale_image_says_upgrade() {
  setup; rm -f "$G/marker"
  export MAVERICKS_DOCKER_ISO="$WORK/new.iso"; echo new > "$MAVERICKS_DOCKER_ISO"; echo old > "$(dirname "$VMX")/boot2docker.iso"
  run --memory 2048 && fail "can't grow live on an old image"
  out | grep -q 'image-upgrade' || fail "points at image-upgrade, not just a restart (out: $(out))"
  no_change_calls || fail "changes nothing"
  teardown
}
# I-4: a grow that Fusion took but the guest never showed leaves the vmx at the new size: asking again
#      must not report "already" while the guest is short.
case_retry_after_guest_never_showed() {
  setup; : > "$G/lazy"
  MAVERICKS_DOCKER_RESIZE_WAIT=2 run --memory 2048 && fail "first try: the guest never showed it"
  sed 's/^memsize = .*/memsize = "2048"/' "$VMX" > "$VMX.t" && cat "$VMX.t" > "$VMX"   # what Fusion did to the vmx
  run --memory 2048 && fail "the retry must not call it done while the guest shows 1 GB"
  out | grep -qi already && fail "not 'already' (out: $(out))"
  out | grep -q -- --restart || fail "says a restart applies it (out: $(out))"
  teardown
}
# M-5 (re-graded): a memory-only grow is judged on memory; a CPU shortfall it didn't ask about is not its failure.
case_memory_grow_ignores_cpu_shortfall() {
  setup; sed 's/^numvcpus = .*/numvcpus = "2"/' "$VMX" > "$VMX.t" && cat "$VMX.t" > "$VMX"   # guest still shows 1 CPU
  MAVERICKS_DOCKER_RESIZE_WAIT=2 run --memory 2048 || fail "memory grew; an old CPU shortfall doesn't fail it (out: $(out))"
  teardown
}

case_live_grow() {
  setup
  run --memory 2048 --cpus 2 || fail "a live grow succeeds (out: $(out))"
  [ "$(grep '^hotplug' "$G/calls")" = "hotplug --memory 2048
hotplug --cpus 2" ] || fail "memory then CPUs, through the helper (calls: $(cat "$G/calls"))"
  grep -q -e '^dm stop' -e '^dm start' "$G/calls" && fail "a live grow never restarts"
  out | grep -q '^memory_mib=2048$' && out | grep -q '^vcpus=2$' || fail "prints the new size (out: $(out))"
  teardown
}
case_no_args() {
  setup
  run && fail "no size is a usage error"
  out | grep -qi usage || fail "says how to use it (out: $(out))"
  no_change_calls || fail "changes nothing"
  teardown
}
case_same_size() {
  setup
  run --memory 1024 --cpus 1 || fail "the size it already has is not an error"
  out | grep -qi already || fail "says it already has that size (out: $(out))"
  no_change_calls || fail "changes nothing"
  teardown
}
case_shrink_needs_restart() {
  setup
  run --memory 512 && fail "a shrink without --restart is refused"
  out | grep -q -- --restart || fail "names --restart (out: $(out))"
  no_change_calls || fail "changes nothing"
  teardown
}
case_shrink_with_restart() {
  setup
  run --memory 512 --restart || fail "a shrink with --restart succeeds (out: $(out))"
  grep -q '^dm stop' "$G/calls" && grep -q '^dm start' "$G/calls" || fail "stops and starts the VM (calls: $(cat "$G/calls"))"
  grep -q '^hotplug' "$G/calls" && fail "a restart change never hot-adds"
  [ "$(vmx_size)" = 512/1 ] || fail "writes the new size into the vmx (got $(vmx_size))"
  teardown
}
case_mixed_is_restart() {
  setup
  run --memory 512 --cpus 2 && fail "less memory and more CPUs is a restart change as a whole"
  no_change_calls || fail "refused, it changes nothing"
  run --memory 512 --cpus 2 --restart || fail "with --restart it goes (out: $(out))"
  [ "$(grep -c '^dm stop' "$G/calls")" = 1 ] && [ "$(grep -c '^dm start' "$G/calls")" = 1 ] || fail "one restart (calls: $(cat "$G/calls"))"
  [ "$(vmx_size)" = 512/2 ] || fail "both sizes written (got $(vmx_size))"
  teardown
}
case_old_vm_needs_restart() {
  setup
  printf 'memsize = "1024"\nnumvcpus = "1"\npowerType.suspend = "soft"\nmem.hotadd = "TRUE"\nsuspend.disabled = "TRUE"\n' > "$VMX"
  run --memory 2048 && fail "a VM from before hot-add can't grow live"
  out | grep -q -- --restart || fail "names --restart (out: $(out))"
  no_change_calls || fail "changes nothing"
  run --memory 2048 --restart || fail "with --restart it goes (out: $(out))"
  grep -q '^hotplug' "$G/calls" && fail "by restart, not hot-add"
  [ "$(vmx_size)" = 2048/1 ] || fail "size written (got $(vmx_size))"
  grep -q '^vcpu\.hotadd = "TRUE"$' "$VMX" || fail "the start prepared the VM for hot-add next time"
  teardown
  setup; rm -f "$G/marker"   # the vmx is ready, but the guest booted an old ISO's kernel
  run --memory 2048 && fail "a guest kernel that can't take a hot-add can't grow live"
  out | grep -q -- --restart || fail "names --restart (out: $(out))"
  no_change_calls || fail "changes nothing"
  teardown
}
case_bad_values() {
  for _a in "--memory 1030" "--memory 32768" "--memory 0" "--cpus 8" "--cpus x" "--cpus 0" "--memory" "--bogus 1"; do
    setup
    # shellcheck disable=SC2086
    run $_a && fail "resize $_a must be refused"
    no_change_calls || fail "resize $_a changes nothing"
    teardown
  done
}
case_live_needs_running() {
  setup; echo Stopped > "$G/status"
  run --memory 2048 && fail "a stopped VM can't grow live"
  out | grep -q -- --restart || fail "names --restart (out: $(out))"
  no_change_calls || fail "changes nothing"
  teardown
}
case_restart_on_stopped() {
  setup; echo Stopped > "$G/status"
  run --memory 2048 --restart || fail "--restart on a stopped VM sets the size and starts it (out: $(out))"
  grep -q '^dm stop' "$G/calls" && fail "nothing to stop"
  grep -q '^dm start' "$G/calls" || fail "started (calls: $(cat "$G/calls"))"
  [ "$(vmx_size)" = 2048/1 ] || fail "size written (got $(vmx_size))"
  teardown
  setup; echo Stopped > "$G/status"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR"; echo boot-1 > "$MAVERICKS_DOCKER_STATE_DIR/user-stopped"
  run --memory 2048 --restart || fail "a user-stopped VM still gets the size (out: $(out))"
  grep -q '^dm start' "$G/calls" && fail "the user stopped it: it stays stopped"
  [ "$(vmx_size)" = 2048/1 ] || fail "size written (got $(vmx_size))"
  out | grep -qi stopped || fail "says it stays stopped (out: $(out))"
  teardown
}
case_no_room() {
  setup; echo $(( 4 * 1048576 )) > "$G/avail-kb"   # 4 GB free: not enough for 1 GB more + 4 GB headroom
  run --memory 2048 && fail "a live grow needs room for the bigger .vmem"
  out | grep -q 'GB' || fail "says how much room it needs (out: $(out))"
  no_change_calls || fail "changes nothing"
  run --memory 8192 --restart && fail "a restart to a bigger size needs room too"
  no_change_calls || fail "changes nothing"
  teardown
}
case_guest_never_sees_it() {
  setup; : > "$G/lazy"
  MAVERICKS_DOCKER_RESIZE_WAIT=2 run --memory 2048 && fail "Fusion accepting it isn't enough: the guest must show it"
  out | grep -qi "didn't show" || fail "says the VM didn't show the new size (out: $(out))"
  teardown
}
case_helper_fails() {
  setup; echo 4 > "$G/hotplug-rc"
  run --memory 2048 && fail "a failed hot-add fails"
  out | grep -q 'not supported' || fail "relays the helper's reason (out: $(out))"
  teardown
}
case_busy() {
  setup
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"; echo $$ > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid"; echo start > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"
  run --memory 2048 && fail "never alongside another operation"
  out | grep -q 'Another Docker operation' || fail "says why (out: $(out))"
  no_change_calls || fail "changes nothing"
  teardown
}

case_live_grow
case_live_cap_from_small_boot
case_no_args
case_same_size
case_shrink_needs_restart
case_shrink_with_restart
case_mixed_is_restart
case_old_vm_needs_restart
case_bad_values
case_live_needs_running
case_restart_on_stopped
case_no_room
case_guest_never_sees_it
case_helper_fails
case_busy
case_paused_for_host_disk
case_status_flaps_but_vmx_alive
case_suspended_vm
case_stale_image_says_upgrade
case_retry_after_guest_never_showed
case_memory_grow_ignores_cpu_shortfall
echo "docker_resize_test: OK"
