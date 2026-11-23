#!/bin/sh
# platform: host-agnostic
# Unit tests for docker-machine-ctl verbs via PATH stubs.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CTL="$ROOT/payload/docker-machine-ctl"
[ -f "$CTL" ] || { echo "docker_ctl_test: ctl missing" >&2; exit 1; }
fail() { echo "docker_ctl_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-ctl.XXXXXX")
  BIN="$WORK/bin"; mkdir -p "$BIN"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state"
  export MAVERICKS_DOCKER_LOG="$WORK/log"
  export MAVERICKS_DOCKER_FUSION_PRESENT=1
  export MAVERICKS_DOCKER_COMMON="$ROOT/payload/docker-machine-common.sh"
  export DM_LOG="$WORK/dm.args"; : > "$DM_LOG"
  export LC_LOG="$WORK/lc.args"; : > "$LC_LOG"
  export DOCKER_LOG="$WORK/docker.args"; : > "$DOCKER_LOG"
  export NOTIFY_LOG="$WORK/notify.args"; : > "$NOTIFY_LOG"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$NOTIFY_LOG" > "$BIN/notifyutil"; chmod +x "$BIN/notifyutil"
  OLDPATH=$PATH; PATH="$BIN:$PATH"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }
# The shell no longer writes the menu's cache files (2026-11-23): it posts a notification and the
# menu asks overview-status. announced = a change notification went out; sw = announced + the word.
NOTE=dev.mavergreen.container-tools.changed
announced() { grep -q -- "-p $NOTE" "$NOTIFY_LOG"; }
sw() { announced || { echo NOT-ANNOUNCED; return; }; ( . "${MAVERICKS_DOCKER_COMMON:-$COMMON}"; status_word ); }
no_caches() { for _f in state readiness disk; do [ -e "$MAVERICKS_DOCKER_STATE_DIR/$_f" ] && return 1; done; return 0; }

stub_dm() { # $1 = status word
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
[ "\$1" = status ] && { echo "$1"; exit 0; }
exit 0
EOF
  chmod +x "$BIN/docker-machine"
}
stub_launchctl() { # $1 = exit code for "list" (0 = loaded/on, 1 = not loaded/off)
  cat > "$BIN/launchctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$LC_LOG"
case "\$1" in list) exit $1 ;; *) exit 0 ;; esac
EOF
  chmod +x "$BIN/launchctl"
}

case_status() {
  setup; stub_dm Running
  [ "$(sh "$CTL" status)" = running ] || fail "status running"
  no_caches || fail "status writes no cache file"
  teardown
}
case_start_stop() {
  setup; stub_dm Running
  sh "$CTL" start >/dev/null || fail "start exit 0"
  grep -q '^start container-tools' "$DM_LOG" || fail "start calls docker-machine start container-tools"
  sh "$CTL" stop >/dev/null || fail "stop exit 0"
  grep -q '^stop container-tools' "$DM_LOG" || fail "stop calls docker-machine stop container-tools"
  teardown
}

# The menu's Stop records that the user wants the VM down (for this boot), so the login agent's
# 60s tick leaves it alone; anything that brings the VM up again clears that.
UMARK() { echo "$MAVERICKS_DOCKER_STATE_DIR/user-stopped"; }

# The VM's disk, for the menu: "<total KB> <used KB> <avail KB> ok|low", or "unknown". Read from df
# inside the VM (docker's data lives on /mnt/sda1), "low" at 90% used the way df counts Capacity
# (used / (used + avail)); the menu gets it from overview-status.
stub_dm_df() { # $1 = status word, $2 = df's data line (empty: ssh fails)
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo "$1"; exit 0 ;;
  ssh) [ -n "$2" ] || exit 1
       echo 'Filesystem           1024-blocks    Used Available Capacity Mounted on'
       echo "$2" ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker-machine"
}
case_disk_status_ok() {
  setup; stub_dm_df Running '/dev/sda1             18668944  12460804   5219012  70% /mnt/sda1'
  [ "$(sh "$CTL" disk-status)" = "18668944 12460804 5219012 ok" ] || fail "disk-status should report total/used/avail KB and ok at 70%"
  no_caches || fail "disk-status writes no cache file"
  grep -q '^ssh container-tools df -P /mnt/sda1' "$DM_LOG" || fail "disk-status must read df of /mnt/sda1 inside the VM"
  teardown
}
case_disk_status_low() {
  setup; stub_dm_df Running '/dev/sda1             18668944  16000000   1700000  91% /mnt/sda1'
  [ "$(sh "$CTL" disk-status)" = "18668944 16000000 1700000 low" ] || fail "disk-status should say low at 90% or more used"
  teardown
}
case_disk_status_unknown() {
  setup; stub_dm_df Stopped '/dev/sda1 1 1 1 1% /mnt/sda1'
  [ "$(sh "$CTL" disk-status)" = unknown ] || fail "a stopped VM's disk is unknown"
  grep -q '^ssh' "$DM_LOG" && fail "disk-status must not ssh into a VM that is not running"
  teardown
  setup; stub_dm_df Running ''
  [ "$(sh "$CTL" disk-status)" = unknown ] || fail "a failed df is unknown, not a number"
  no_caches || fail "disk-status writes no cache file"
  teardown
}

# "Free Up Space…": the confirmation shows what docker says can be freed, and the cleanup removes only
# unused images and build cache -- never containers or volumes, which can hold the user's data.
stub_docker_df() {
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$*" in
  *"system df"*) printf 'Images|9.832GB|2.804GB (28%%)\nContainers|200.5MB|194MB (96%%)\nLocal Volumes|1.876GB|396B (0%%)\nBuild Cache|1.2GB|0.8GB\n' ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker"
}
case_reclaimable() {
  setup; stub_dm_df Running '/dev/sda1 18668944 12460804 5219012 70% /mnt/sda1'; stub_docker_df
  out=$(sh "$CTL" reclaimable) || fail "reclaimable exit 0"
  [ "$out" = "$(printf 'Unused images: 2.804GB\nBuild cache: 0.8GB')" ] \
    || fail "reclaimable should list only what free-space removes (got: $out)"
  grep -q -- '--context mavericks system df' "$DOCKER_LOG" || fail "reclaimable must ask the mavericks context"
  teardown
}
case_free_space() {
  setup; stub_dm_df Running '/dev/sda1 18668944 12460804 5219012 70% /mnt/sda1'; stub_docker_df
  sh "$CTL" free-space >/dev/null || fail "free-space exit 0"
  grep -q -- '--context mavericks image prune -a -f' "$DOCKER_LOG" || fail "free-space must remove unused images"
  grep -q -- '--context mavericks builder prune -f' "$DOCKER_LOG" || fail "free-space must remove build cache"
  if grep -E -e 'volume' -e 'container prune' -e 'system prune' "$DOCKER_LOG"; then
    fail "free-space must never remove containers or volumes"
  fi
  announced || fail "free-space must announce"; no_caches || fail "free-space writes no cache file"
  teardown
}
# auto-free: what the login agent's tick runs on a low disk, also callable by hand. Only dangling
# images and build cache; refused while another op holds op.lock, so it never runs under a start,
# stop or upgrade.
case_auto_free() {
  setup; stub_dm_df Running '/dev/sda1 18668944 12460804 5219012 70% /mnt/sda1'; stub_docker_df
  sh "$CTL" auto-free >/dev/null || fail "auto-free exit 0"
  grep -qx -- '--context mavericks image prune -f' "$DOCKER_LOG" || fail "auto-free must remove dangling images"
  grep -qx -- '--context mavericks builder prune -f' "$DOCKER_LOG" || fail "auto-free must remove build cache"
  grep -q -- 'prune -a\|--all\|volume\|container prune\|system prune' "$DOCKER_LOG" \
    && fail "auto-free must never remove tagged images, containers or volumes"
  announced || fail "auto-free must announce"; no_caches || fail "auto-free writes no cache file"
  [ -s "$MAVERICKS_DOCKER_STATE_DIR/auto-free-last" ] || fail "auto-free must record when it ran"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "auto-free must release op.lock"
  teardown
}
case_auto_free_waits_for_op() {
  setup; stub_dm_df Running '/dev/sda1 18668944 16000000 1700000 91% /mnt/sda1'; stub_docker_df
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"  # portability-ok: pre-creates a held lock for the test; no race
  echo image-upgrade > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"; echo $$ > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid"
  sh "$CTL" auto-free >/dev/null && fail "auto-free must fail while another op holds op.lock"
  grep -q prune "$DOCKER_LOG" && fail "auto-free must not prune while another op holds op.lock"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name")" = image-upgrade ] || fail "auto-free must leave another op's lock alone"
  teardown
}
# disk-advice: when the disk is still low after auto-free, name what fills it and the action that
# fits. Reads docker's own accounting plus the containers' json logs; reports only, never deletes.
# $1..$4 = Images reclaimable, Containers reclaimable, Local Volumes size, the largest log's KB.
stub_advice() {
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$*" in
  *"system df -v"*) printf 'Local Volumes space usage:\n\nVOLUME NAME               LINKS     SIZE\nsmall-data   1   24.3MB\nsignal-desktop-gui-data   1   $3\n\nBuild cache usage: 0B\n' ;;
  *"system df"*) printf 'Images|5.688GB|$1 (4%%)\nContainers|200.5MB|$2 (96%%)\nLocal Volumes|$3|396B (0%%)\nBuild Cache|0B|0B\n' ;;
  *"ps -a"*) printf '64e93d836de8f14ab 1password-gui\nf92f352dec63ee5d4 signal-desktop-gui\n' ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  ssh) case "\$*" in
         *json.log*) printf '%s\t/var/lib/docker/containers/f92f352dec63ee5d4/f92f352dec63ee5d4-json.log\n12\t/var/lib/docker/containers/64e93d836de8f14ab/64e93d836de8f14ab-json.log\n' "$4" ;;
       esac ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker-machine"
}
case_disk_advice() {
  setup; stub_advice 3.2GB 194MB 1.9GB 40
  out=$(sh "$CTL" disk-advice) || fail "disk-advice exit 0"
  case "$out" in *"unused images hold 3.2 GB"*"Free Up Space"*) ;; *) fail "images biggest: point at Free Up Space (got: $out)" ;; esac
  teardown
  setup; stub_advice 274MB 2.5GB 1.9GB 40
  out=$(sh "$CTL" disk-advice)
  case "$out" in *"stopped containers hold 2.5 GB"*) ;; *) fail "stopped containers biggest: say so (got: $out)" ;; esac
  teardown
  setup; stub_advice 274MB 194MB 12.4GB 40
  out=$(sh "$CTL" disk-advice)
  case "$out" in *"volumes hold 12.4 GB"*"signal-desktop-gui-data"*"Enlarge VM Disk"*) ;; *) fail "volumes biggest: name the largest, never offer to delete it (got: $out)" ;; esac
  case "$out" in *"Free Up Space"*|*[Rr]emove*|*[Dd]elete*) fail "never suggest deleting a volume (got: $out)" ;; esac
  teardown
  setup; stub_advice 274MB 194MB 1.9GB 3400000
  out=$(sh "$CTL" disk-advice)
  case "$out" in *"log of container signal-desktop-gui is 3.5 GB"*) ;; *) fail "a huge log: name its container (got: $out)" ;; esac
  teardown
  setup; stub_advice 274MB 194MB 600MB 40
  out=$(sh "$CTL" disk-advice)
  case "$out" in *"Enlarge VM Disk"*) ;; *) fail "nothing large to free: point at Enlarge VM Disk (got: $out)" ;; esac
  grep -E -q 'prune|rm |volume rm' "$DOCKER_LOG" && fail "disk-advice must only report"
  teardown
}
# enlarge-disk: the procedure proven by hand on 2026-11-21 (20 GB to 50 GB, nothing lost). Stop, grow
# the sparse vmdk with vmware-vdiskmanager -x, start, then grow sda1 and its ext4 online. Refuses,
# before stopping anything, unless the VM is running, the vmdk is one sparse file with no snapshot,
# sda1 is the last partition, the new size is bigger, and the Mac has room. Runs under op.lock.
VMDIR() { echo "$HOME/.docker/machine/machines/container-tools"; }
stub_enlarge() { # $1 = layout: last | first ; $2 = vdiskmanager exit code
  mkdir -p "$(VMDIR)"
  printf 'KDMV\n# Disk DescriptorFile\ncreateType="monolithicSparse"\n# Extent description\nRW 40960000 SPARSE "container-tools.vmdk"\n' > "$(VMDIR)/container-tools.vmdk"
  : > "$(VMDIR)/container-tools.vmsd"
  echo Running > "$WORK/vmstate"
  if [ "$1" = last ]; then
    printf '/dev/sda1 : start=     2050048, size=    38909919, type=L\n/dev/sda2 : start=        2048, size=     2048000, type=S\n' > "$WORK/dump"
  else
    printf '/dev/sda1 : start=        2048, size=    38909919, type=L\n/dev/sda2 : start=    38911967, size=     2048000, type=S\n' > "$WORK/dump"
  fi
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) cat "$WORK/vmstate" ;;
  stop)   echo Stopped > "$WORK/vmstate" ;;
  start)  echo Running > "$WORK/vmstate" ;;
  ssh) case "\$*" in
         *"sfdisk --dump"*) cat "$WORK/dump" ;;
         *"df -P"*) echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'; echo '/dev/sda1 49611072 9480476 37866540 20% /mnt/sda1' ;;
       esac ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker-machine"
  printf '#!/bin/sh\n[ "$(cat "%s/vmstate")" = Running ] && echo 4242\nexit 0\n' "$WORK" > "$BIN/pgrep"; chmod +x "$BIN/pgrep"
  printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 1 1 %s 50%% /"\n' "${MAC_AVAIL_KB:-73400320}" > "$BIN/df"; chmod +x "$BIN/df"
  cat > "$BIN/vdiskmanager" <<EOF
#!/bin/sh
printf 'vdm %s [%s]\n' "\$*" "\$(cat "$WORK/vmstate")" >> "$DM_LOG"
[ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] || echo "vdiskmanager without op.lock" >> "$WORK/violations"
exit $2
EOF
  chmod +x "$BIN/vdiskmanager"
  export MAVERICKS_DOCKER_VDISKMANAGER="$BIN/vdiskmanager"
}
case_enlarge_disk_plan() {
  setup; stub_enlarge last 0
  out=$(sh "$CTL" enlarge-disk-plan) || fail "enlarge-disk-plan exit 0 (got: $out)"
  [ "$out" = "20 40 25 70" ] || fail "plan: current GB, new GB (+20), Mac GB needed (growth + 4 headroom), Mac GB free (got: $out)"
  out=$(sh "$CTL" enlarge-disk-plan 50) || fail "a bigger explicit size is fine"
  [ "$out" = "20 50 35 70" ] || fail "plan with an explicit size (got: $out)"
  sh "$CTL" enlarge-disk-plan 19 >/dev/null 2>&1 && fail "a size no bigger than the disk must be refused"
  grep -q '^stop' "$DM_LOG" && fail "planning must not stop the VM"
  teardown
}
case_enlarge_disk() {
  setup; stub_enlarge last 0
  sh "$CTL" enlarge-disk >/dev/null || fail "enlarge-disk exit 0"
  grep -q '^stop container-tools' "$DM_LOG" || fail "enlarge-disk must stop the VM before growing the vmdk"
  grep -qx "vdm -x 40GB $(VMDIR)/container-tools.vmdk \[Stopped\]" "$DM_LOG" || fail "vdiskmanager -x must grow the vmdk while the VM is stopped (got: $(grep vdm "$DM_LOG"))"
  grep -q '^start container-tools' "$DM_LOG" || fail "enlarge-disk must start the VM again"
  grep -q 'sfdisk --no-reread -N 1 /dev/sda' "$DM_LOG" || fail "enlarge-disk must grow sda1 to the new end"
  grep -q 'partx -u /dev/sda' "$DM_LOG" || fail "enlarge-disk must tell the kernel the new partition size"
  grep -q 'resize2fs /dev/sda1' "$DM_LOG" || fail "enlarge-disk must grow the ext4 online"
  [ "$(sed -n '/^stop/=' "$DM_LOG" | head -1)" -lt "$(sed -n '/^vdm/=' "$DM_LOG")" ] || fail "stop before vdiskmanager"
  [ "$(sed -n '/^vdm/=' "$DM_LOG")" -lt "$(sed -n '/resize2fs/=' "$DM_LOG")" ] || fail "partition grow after the vmdk grow"
  [ -f "$WORK/violations" ] && fail "$(cat "$WORK/violations")"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "enlarge-disk must release op.lock"
  no_caches || fail "enlarge-disk writes no cache file"
  [ "$(sw)" = running ] || fail "enlarge-disk must announce the settled state"
  teardown
}
case_enlarge_disk_refusals() {
  setup; stub_enlarge first 0
  sh "$CTL" enlarge-disk >/dev/null 2>&1 && fail "sda1 not last: refuse"
  grep -q '^stop' "$DM_LOG" && fail "a refused enlarge-disk must not stop the VM (sda1 not last)"
  teardown
  setup; stub_enlarge last 0; : > "$(VMDIR)/container-tools-000001.vmdk"
  sh "$CTL" enlarge-disk >/dev/null 2>&1 && fail "a snapshot delta disk: refuse"
  grep -q '^stop' "$DM_LOG" && fail "a refused enlarge-disk must not stop the VM (snapshot)"
  teardown
  setup; stub_enlarge last 0; sed -i '' 's/monolithicSparse/monolithicFlat/' "$(VMDIR)/container-tools.vmdk"
  sh "$CTL" enlarge-disk >/dev/null 2>&1 && fail "not one sparse file: refuse"
  teardown
  setup; MAC_AVAIL_KB=10485760 stub_enlarge last 0
  out=$(sh "$CTL" enlarge-disk 2>&1) && fail "no room on the Mac: refuse"
  case "$out" in *"GB free"*) ;; *) fail "the no-room refusal must give the numbers (got: $out)" ;; esac
  grep -q '^stop' "$DM_LOG" && fail "a refused enlarge-disk must not stop the VM (no room)"
  teardown
  setup; stub_enlarge last 0; echo Stopped > "$WORK/vmstate"
  sh "$CTL" enlarge-disk >/dev/null 2>&1 && fail "a stopped VM: refuse (its partition layout can't be checked)"
  grep -q '^vdm' "$DM_LOG" && fail "a refused enlarge-disk must not grow the vmdk"
  teardown
  setup; stub_enlarge last 0; mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"  # portability-ok: pre-creates a held lock for the test; no race
  echo start > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"; echo $$ > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid"
  sh "$CTL" enlarge-disk >/dev/null 2>&1 && fail "another op holds op.lock: refuse"
  grep -q '^stop' "$DM_LOG" && fail "enlarge-disk must not stop the VM under another op"
  teardown
}
case_enlarge_disk_vdm_fails() {
  setup; stub_enlarge last 3
  sh "$CTL" enlarge-disk >/dev/null 2>&1 && fail "a failed vdiskmanager must fail enlarge-disk"
  grep -q '^start container-tools' "$DM_LOG" || fail "a failed vdiskmanager must still bring the VM back up"
  grep -q 'resize2fs' "$DM_LOG" && fail "a failed vdiskmanager must not touch the partition"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "a failed enlarge-disk must release op.lock"
  teardown
}
# Readiness (2026-11-22): "running" is power, not Docker. Ready means the managed context answers an
# authenticated API call. $WORK/vmstate is the VM's power; $WORK/api is how `docker info` behaves:
# ok | tls (unknown authority) | down | hang. The bootstrap stub stands in for the noninteractive
# setup path that ensure-ready runs on a stopped VM.
stub_ready() { # $1 = vmstate, $2 = api
  echo "$1" > "$WORK/vmstate"; echo "$2" > "$WORK/api"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) cat "$WORK/vmstate" ;;
  regenerate-certs) echo ok > "$WORK/api" ;;
esac
exit 0
EOF
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s DOCKER_HOST=%s\n' "\$*" "\${DOCKER_HOST:-}" >> "$DOCKER_LOG"
case "\$*" in
  *" info "*|*" info") case "\$(cat "$WORK/api")" in
      ok)   echo 23.0.6 ;;
      tls)  echo 'tls: failed to verify certificate: x509: certificate signed by unknown authority' >&2; exit 1 ;;
      down) echo 'dial tcp 192.168.237.137:2376: connect: host is down' >&2; exit 1 ;;
      hang) sleep 30 ;;
    esac ;;
esac
exit 0
EOF
  cat > "$BIN/docker-machine-bootstrap" <<EOF
#!/bin/sh
echo bootstrap >> "$DM_LOG"
echo Running > "$WORK/vmstate"; echo ok > "$WORK/api"
EOF
  chmod +x "$BIN/docker-machine" "$BIN/docker" "$BIN/docker-machine-bootstrap"
}
case_readiness() {
  setup
  [ "$(sh "$CTL" readiness-version)" = 1 ] || fail "readiness-version must print 1"
  stub_ready Running ok
  out=$(DOCKER_HOST=tcp://elsewhere:2376 sh "$CTL" readiness) || fail "running + API ok must be ready, exit 0 (got: $out)"
  [ "$out" = ready ] || fail "readiness prints ready (got: $out)"
  grep -q -- '--context mavericks info' "$DOCKER_LOG" || fail "readiness must ask the managed context explicitly"
  grep -q 'DOCKER_HOST=tcp' "$DOCKER_LOG" && fail "readiness must clear inherited DOCKER_HOST, so only the managed context can pass"
  echo tls > "$WORK/api"
  out=$(sh "$CTL" readiness) && fail "unknown authority is not ready"
  [ "$out" = needs-attention ] || fail "unknown authority -> needs-attention (got: $out)"
  echo down > "$WORK/api"
  [ "$(sh "$CTL" readiness)" = finishing-setup ] || fail "running but the API not answering yet -> finishing-setup"
  echo Stopped > "$WORK/vmstate"
  [ "$(sh "$CTL" readiness)" = stopped ] || fail "a stopped VM -> stopped"
  echo Running > "$WORK/vmstate"; echo ok > "$WORK/api"; mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"  # portability-ok: pre-creates a held lock for the test; no race
  echo restart > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"; echo $$ > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid"
  [ "$(sh "$CTL" readiness)" = working:restart ] || fail "an op in progress -> working:<op>"
  rm -rf "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  rc=0; sh "$CTL" readiness --wait-seconds x >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a bad --wait-seconds exits 2 (got $rc)"
  teardown
}
case_readiness_hang_is_bounded() {
  setup; stub_ready Running hang
  t0=$(date +%s)
  out=$(sh "$CTL" readiness --wait-seconds 2) && fail "a hung API is not ready"
  [ $(( $(date +%s) - t0 )) -le 6 ] || fail "readiness must give up on a hung API within its budget"
  [ "$out" = finishing-setup ] || fail "a hung API -> finishing-setup (got: $out)"
  teardown
}
case_ensure_ready() {
  setup; stub_ready Stopped down
  out=$(sh "$CTL" ensure-ready --wait-seconds 5) || fail "ensure-ready must bring a stopped VM to ready (got: $out)"
  [ "$out" = ready ] || fail "ensure-ready prints ready (got: $out)"
  grep -q '^bootstrap' "$DM_LOG" || fail "ensure-ready starts a stopped VM through the noninteractive bootstrap"
  teardown
  setup; stub_ready Stopped down; MAVERICKS_DOCKER_BOOT_ID=b1 sh "$CTL" stop >/dev/null; : > "$DM_LOG"
  out=$(MAVERICKS_DOCKER_BOOT_ID=b1 sh "$CTL" ensure-ready --wait-seconds 3) && fail "the user's Stop must be respected"
  [ "$out" = stopped ] || fail "user-stopped -> stopped (got: $out)"
  grep -q '^bootstrap\|^start' "$DM_LOG" && fail "ensure-ready must not start a VM the user stopped this boot"
  teardown
  setup; stub_ready Running ok; echo NotExist > "$WORK/vmstate"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"; exit 1\n' "$DM_LOG" > "$BIN/docker-machine"; chmod +x "$BIN/docker-machine"
  out=$(sh "$CTL" ensure-ready --wait-seconds 3) && fail "an absent VM is not ready"
  [ "$out" = absent ] || fail "absent -> absent, for the caller to point at setup (got: $out)"
  grep -q '^bootstrap' "$DM_LOG" && fail "ensure-ready must never create a VM: that's setup"
  teardown
  setup; stub_ready Running down
  t0=$(date +%s)
  rc=0; out=$(sh "$CTL" ensure-ready --wait-seconds 3) || rc=$?
  [ "$rc" -eq 124 ] || fail "never ready within the budget exits 124 (got $rc)"
  [ "$out" = finishing-setup ] || fail "and prints the last state (got: $out)"
  [ $(( $(date +%s) - t0 )) -le 8 ] || fail "ensure-ready must respect its budget"
  teardown
  setup; stub_ready Running tls
  t0=$(date +%s)
  out=$(sh "$CTL" ensure-ready --wait-seconds 30) && fail "unknown authority is not ready"
  [ "$out" = needs-attention ] || fail "unknown authority -> needs-attention (got: $out)"
  [ $(( $(date +%s) - t0 )) -le 5 ] || fail "needs-attention won't fix itself: report it at once, don't wait out the budget"
  grep -q regenerate-certs "$DM_LOG" && fail "ensure-ready must never regenerate certs by itself (that restarts the daemon): Repair is explicit"
  teardown
}
case_repair() {
  setup; stub_ready Running tls
  out=$(sh "$CTL" repair) || fail "repair must fix unknown authority (got: $out)"
  [ "$out" = ready ] || fail "repair prints the resulting state (got: $out)"
  grep -q '^regenerate-certs -f container-tools' "$DM_LOG" || fail "repair regenerates the machine's server certs"
  grep -q -- '--client-certs' "$DM_LOG" && fail "repair must never rotate the shared client identity"
  grep -E -q '^(rm|create|kill)' "$DM_LOG" && fail "repair must never remove or recreate the VM"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "repair must release op.lock"
  announced || fail "repair must announce"; no_caches || fail "repair writes no readiness file"
  teardown
  setup; stub_ready Running ok
  sh "$CTL" repair >/dev/null || fail "repair on a ready VM is fine"
  grep -q regenerate-certs "$DM_LOG" && fail "repair must not regenerate certs for a ready VM"
  teardown
  setup; stub_ready Running tls; mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"  # portability-ok: pre-creates a held lock for the test; no race
  echo image-upgrade > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"; echo $$ > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid"
  sh "$CTL" repair >/dev/null 2>&1 && fail "repair must refuse while another op runs"
  grep -q regenerate-certs "$DM_LOG" && fail "repair must not touch certs under another op"
  teardown
}
case_diagnostics() {
  setup; stub_ready Running tls
  out=$(sh "$CTL" diagnostics) || fail "diagnostics exit 0"
  case "$out" in *"readiness: needs-attention"*"power: Running"*) ;; *) fail "diagnostics names readiness and power (got: $out)" ;; esac
  case "$out" in *"unknown authority"*) ;; *) fail "diagnostics shows the API error (got: $out)" ;; esac
  case "$out" in *"BEGIN"*|*"PRIVATE"*) fail "diagnostics must never print key material" ;; esac
  teardown
}
# overview-status (2026-11-23): everything the menu shows, from one bounded call; no cache files.
ov() { sh "$CTL" overview-status "$@"; }
ov_field() { ov | sed -n "s/^$1 //p"; }
case_overview_status() {
  setup; stub_ready Running ok; stub_launchctl 0
  out=$(ov) || fail "overview-status exits 0"
  [ "$(printf '%s\n' "$out" | head -1)" = "version 1" ] || fail "line 1 is 'version 1' (got: $out)"
  printf '%s\n' "$out" | grep -q '^state running$' || fail "running + API ok -> state running (got: $out)"
  printf '%s\n' "$out" | grep -q '^vmx-pid [0-9]*$' || fail "a vmx-pid line (got: $out)"
  printf '%s\n' "$out" | grep -q '^login on$' || fail "login on (got: $out)"
  printf '%s\n' "$out" | grep -q '^disk ' || fail "a disk line when running (got: $out)"
  ov --full | grep -q '^image ' || fail "--full adds the image line"
  echo tls > "$WORK/api";  [ "$(ov_field state)" = needs-attention ] || fail "unknown authority -> needs-attention"
  echo down > "$WORK/api"; [ "$(ov_field state)" = finishing-setup ] || fail "API not answering -> finishing-setup"
  echo Stopped > "$WORK/vmstate"
  [ "$(ov_field state)" = stopped ] || fail "stopped VM -> state stopped"
  [ "$(ov_field disk)" = unknown ] || fail "stopped VM -> disk unknown"
  : > "$MAVERICKS_DOCKER_STATE_DIR/boot-refused"
  [ "$(ov_field state)" = host-disk-full ] || fail "a remembered boot refusal on a stopped VM -> host-disk-full"
  rm -f "$MAVERICKS_DOCKER_STATE_DIR/boot-refused"
  echo Running > "$WORK/vmstate"; echo ok > "$WORK/api"; : > "$DOCKER_LOG"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"  # portability-ok: pre-creates a held lock for the test; no race
  echo stop > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"; echo $$ > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/pid"
  out=$(ov)
  printf '%s\n' "$out" | grep -q '^state working:stop$' || fail "an op in progress -> working:<op> (got: $out)"
  printf '%s\n' "$out" | grep -q '^disk ' && fail "no disk line while an op holds the VM (keep the last value)"
  grep -q ' info' "$DOCKER_LOG" && fail "no Docker probe while an op holds the VM"
  rm -rf "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  for f in state readiness disk; do echo x > "$MAVERICKS_DOCKER_STATE_DIR/$f"; done
  ov >/dev/null
  for f in state readiness disk; do [ -e "$MAVERICKS_DOCKER_STATE_DIR/$f" ] && fail "overview-status removes the old $f cache file"; done
  teardown
}
case_overview_api_hang_is_bounded() {
  setup; stub_ready Running hang; stub_launchctl 0
  t0=$(date +%s); st=$(ov_field state)
  [ $(( $(date +%s) - t0 )) -le 6 ] || fail "overview-status must finish within ~5 s on a hung API"
  [ "$st" = finishing-setup ] || fail "a hung API -> finishing-setup (got: $st)"
  teardown
}
case_overview_dm_hang_is_bounded() {
  setup; stub_ready Running ok; stub_launchctl 0
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
[ "\$1" = status ] && sleep 30
exit 0
EOF
  chmod +x "$BIN/docker-machine"
  t0=$(date +%s); st=$(ov_field state)
  [ $(( $(date +%s) - t0 )) -le 6 ] || fail "overview-status must finish within ~5 s when docker-machine hangs"
  [ "$st" = error ] || fail "docker-machine not answering -> error (got: $st)"
  teardown
}
case_start_clears_boot_refused() {
  setup; stub_dm Stopped; stub_launchctl 0
  echo 7 > "$MAVERICKS_DOCKER_STATE_DIR/boot-refused" 2>/dev/null || { mkdir -p "$MAVERICKS_DOCKER_STATE_DIR"; echo 7 > "$MAVERICKS_DOCKER_STATE_DIR/boot-refused"; }
  sh "$CTL" start >/dev/null 2>&1 || :
  [ -e "$MAVERICKS_DOCKER_STATE_DIR/boot-refused" ] && fail "the user's Start must forget the login agent's refusal"
  teardown
}
case_no_cache_files() {
  setup; stub_ready Running ok; stub_launchctl 0
  for v in status start stop restart repair disk-status diagnostics overview-status; do
    sh "$CTL" $v >/dev/null 2>&1 || :
    no_caches || fail "$v must not write the menu's old cache files"
  done
  teardown
}
case_stop_marks_user_stopped() {
  setup; stub_dm Stopped
  MAVERICKS_DOCKER_BOOT_ID=boot-A sh "$CTL" stop >/dev/null || fail "stop exit 0"
  [ "$(cat "$(UMARK)" 2>/dev/null)" = boot-A ] || fail "stop must record user-stopped with this boot's id"
  teardown
}
case_failed_stop_marks_nothing() {
  setup
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
[ "\$1" = status ] && { echo Running; exit 0; }
[ "\$1" = stop ] && exit 1
exit 0
EOF
  chmod +x "$BIN/docker-machine"
  MAVERICKS_DOCKER_BOOT_ID=boot-A sh "$CTL" stop >/dev/null && fail "a failed stop should exit non-zero"
  [ -f "$(UMARK)" ] && fail "a failed stop must not mark the VM user-stopped"
  teardown
}
case_up_verbs_clear_user_stopped() {
  for verb in start restart image-upgrade; do
    setup; stub_dm Running
    mkdir -p "$MAVERICKS_DOCKER_STATE_DIR"; echo boot-A > "$(UMARK)"
    MAVERICKS_DOCKER_BOOT_ID=boot-A sh "$CTL" "$verb" >/dev/null 2>&1 || :
    [ -f "$(UMARK)" ] && fail "ctl $verb brings the VM up, so it must clear user-stopped"
    teardown
  done
  setup
  printf '#!/bin/sh\nexit 0\n' > "$BIN/docker-machine-bootstrap"; chmod +x "$BIN/docker-machine-bootstrap"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR"; echo boot-A > "$(UMARK)"
  MAVERICKS_DOCKER_BOOT_ID=boot-A sh "$CTL" setup >/dev/null 2>&1 || :
  [ -f "$(UMARK)" ] && fail "ctl setup (Set Up / Repair) must clear user-stopped so bootstrap brings the VM up"
  teardown
}

# VM up on a NEW IP while the mavericks context still holds the OLD IP — the renumber that
# makes `docker ps` hang. A running-VM verb must self-heal by re-pointing the context.
# (docker-machine env reports the VM's real current IP, so detection never hangs on the stale one.)
stub_renumbered() {
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  env) echo 'export DOCKER_HOST="tcp://10.0.0.5:2376"'; echo 'export DOCKER_CERT_PATH="/tmp/certs"' ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker-machine"
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$*" in
  *"context inspect mavericks --format"*) echo "tcp://10.0.0.4:2376" ;;   # stale (old) host
  *"context inspect mavericks"*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker"
}
case_start_syncs_context() {
  setup; stub_renumbered
  sh "$CTL" start >/dev/null || fail "start exit 0"
  grep -q '^start container-tools' "$DM_LOG" || fail "start calls docker-machine start"
  grep -q '^env container-tools' "$DM_LOG" || fail "start must sync context after starting"
  grep -q 'context update mavericks' "$DOCKER_LOG" || fail "start must re-point mavericks at the current IP"
  grep -q 'context use mavericks' "$DOCKER_LOG" || fail "start must select the mavericks context"
  teardown
}
# No sync on the read path: status must stay fast (no docker-machine env) — there's no cheap
# renumber detector, so healing every poll would tax the happy path. Renumber is a restart
# event (start/restart heals) and the login-agent timer covers out-of-band restarts.
case_status_stays_fast() {
  setup; stub_renumbered
  [ "$(sh "$CTL" status)" = running ] || fail "status running"
  grep -q '^env container-tools' "$DM_LOG" && fail "status must NOT call docker-machine env (keep happy path fast)"
  grep -q 'context update' "$DOCKER_LOG" 2>/dev/null && fail "status must not re-point the context"
  teardown
}
case_login() {
  setup; stub_launchctl 0
  [ "$(sh "$CTL" login-status)" = on ] || fail "loaded -> on"
  stub_launchctl 1
  [ "$(sh "$CTL" login-status)" = off ] || fail "not loaded -> off"
  sh "$CTL" login-on >/dev/null
  grep -q 'load -w /Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist' "$LC_LOG" || fail "login-on loads the plist"
  sh "$CTL" login-off >/dev/null
  grep -q 'unload -w /Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist' "$LC_LOG" || fail "login-off unloads the plist"
  teardown
}
case_vmxpid() {
  setup
  cat > "$BIN/pgrep" <<'EOF'
#!/bin/sh
echo 4242
EOF
  chmod +x "$BIN/pgrep"
  [ "$(sh "$CTL" vmx-pid)" = 4242 ] || fail "vmx-pid prints the pid"
  teardown
}
case_setup() {
  setup
  cat > "$BIN/docker-machine-bootstrap" <<EOF
#!/bin/sh
: > "$WORK/bootstrap-ran"
EOF
  chmod +x "$BIN/docker-machine-bootstrap"
  sh "$CTL" setup || fail "setup exit 0"
  [ -f "$WORK/bootstrap-ran" ] || fail "setup execs docker-machine-bootstrap"
  teardown
}

case_packaging() {
  grep -q -- '--common' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh needs --common"
  grep -q -- '--ctl' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh needs --ctl"
  grep -q 'T/libexec/docker-machine-common.sh' "$ROOT/cmake/package_pkg.sh" \
    || fail "package_pkg.sh must install docker-machine-common.sh"
  grep -q 'T/bin/docker-machine-ctl' "$ROOT/cmake/package_pkg.sh" \
    || fail "package_pkg.sh must install docker-machine-ctl"
  grep -q -- '--common payload/docker-machine-common.sh' "$ROOT/.github/workflows/release.yml" \
    || fail "release.yml must pass --common"
  grep -q -- '--ctl payload/docker-machine-ctl' "$ROOT/.github/workflows/release.yml" \
    || fail "release.yml must pass --ctl"
  grep -q 'T/bin/docker-machine-migrate' "$ROOT/cmake/package_pkg.sh" \
    || fail "package_pkg.sh must install docker-machine-migrate"
  grep -q -- '--migrate payload/docker-machine-migrate' "$ROOT/.github/workflows/release.yml" \
    || fail "release.yml must pass --migrate"
  echo "  ctl-packaging OK"
}

# A run that can publish must be ALONE in its concurrency group. The old shape here was the opposite:
# all dispatches shared one group with cancel-in-progress:false, sold as a version-bump lock. It never
# locked anything -- cancel-in-progress:false protects the RUNNING run, not a QUEUED one, and GitHub
# keeps only the newest pending run per group. A third dispatch cancels the queued second (verified
# 2026-09-09). Two dispatches may now compute the same -mavericks.(N+1); shipyard's publish-release.yml
# refuses the loser at publish time, which is loud where the old shape was silent.
case_release_concurrency() {
  RY="$ROOT/.github/workflows/release.yml"
  grep -qF "github.event_name == 'pull_request'" "$RY" \
    || fail "release.yml: the concurrency group must single out pull_request -- it is the only event that supersedes"
  grep -qF "github.run_id" "$RY" \
    || fail "release.yml: pushes, tags and dispatches must be keyed per RUN, so a publishing run is alone in its group"
  grep -qF "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$RY" \
    || fail "release.yml: only a pull_request may be cancelled by a superseding run"
  # the shape this replaced, in either of its spellings
  if grep -qF "workflow_dispatch' && 'local_release'" "$RY" \
     || grep -qF "cancel-in-progress: \${{ github.event_name != 'workflow_dispatch' }}" "$RY"; then
    fail "release.yml: the shared-dispatch-group 'lock' is back -- it silently evicts queued releases"
  fi
  echo "  release-concurrency OK"
}

# CLI-first image roll: image-status echoes current/stale/absent; image-upgrade repoints a stale
# Boot2DockerURL (Wowfunhappy-migrated hosts hold the vanished DMG path) THEN `docker-machine upgrade`
# and heals. No GUI in the loop — the menu-bar app just shells out to these.
case_image() {
  setup; stub_dm Running
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"; mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  export MAVERICKS_DOCKER_ISO="$WORK/installed.iso"; printf 'NEW\n' > "$MAVERICKS_DOCKER_ISO"
  printf 'OLD\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/boot2docker.iso"
  printf '{ "Boot2DockerURL": "/Volumes/Docker for Mavericks/boot2docker.iso" }\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json"
  [ "$(sh "$CTL" image-status)" = stale ] || fail "image-status must report stale when the VM iso differs"
  sh "$CTL" image-upgrade >/dev/null || fail "image-upgrade exit 0 on success"
  grep -q "\"Boot2DockerURL\": \"$MAVERICKS_DOCKER_ISO\"" "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json" \
    || fail "image-upgrade must repoint Boot2DockerURL to the installed ISO before upgrading"
  grep -q '^upgrade container-tools' "$DM_LOG" || fail "image-upgrade must call docker-machine upgrade"
  grep -q '^start container-tools' "$DM_LOG" || fail "image-upgrade must start the VM after upgrading"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "image-upgrade must release op.lock"
  [ "$(sw)" = running ] || fail "image-upgrade must announce the settled state"
  teardown
}

# A failing `docker-machine upgrade` must (1) make the verb exit non-zero so the app can notify
# failure, and (2) still start the VM so the user is not left with a down machine.
case_image_upgrade_fails() {
  setup
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"; mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  export MAVERICKS_DOCKER_ISO="$WORK/installed.iso"; printf 'NEW\n' > "$MAVERICKS_DOCKER_ISO"
  printf 'OLD\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/boot2docker.iso"
  printf '{ "Boot2DockerURL": "/x" }\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status)  echo Running ;;
  upgrade) exit 3 ;;
  *)       exit 0 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$CTL" image-upgrade >/dev/null && fail "image-upgrade must exit non-zero when upgrade fails"
  grep -q '^start container-tools' "$DM_LOG" || fail "a failed upgrade must still start the VM"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "op.lock must be released even on failure"
  teardown
}

# The verbs that power the VM on refuse when the Mac has no room for its .vmem (see host_room_to_boot)
# -- the power-on inside `docker-machine upgrade` is the one that paused the VM on 2026-10-24. A
# refused image-upgrade leaves a running VM running rather than stopping it into a pause.
case_no_room_to_boot() {
  setup; stub_dm Running
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"; mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "16384"\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  printf '{ "Boot2DockerURL": "/x" }\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json"
  printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 1 1 3000000 99%% /"\n' \
    > "$BIN/df"; chmod +x "$BIN/df"
  sh "$CTL" start >/dev/null && fail "start must fail when there is no room to power on"
  grep -q '^start ' "$DM_LOG" && fail "start must not call docker-machine start without room"
  sh "$CTL" image-upgrade >/dev/null && fail "image-upgrade must fail when there is no room to power on"
  grep -q '^stop \|^upgrade ' "$DM_LOG" && fail "image-upgrade must not stop or upgrade without room"
  grep -q 'GB free' "$MAVERICKS_DOCKER_LOG" || fail "the refusal must say in the log how much space is needed"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "a refused verb must release op.lock"
  teardown
}

# A ctl verb announces working:<op> while it runs; verified here via op_end's cleanup (lock gone,
# state settled). The mid-run working marker itself is exercised in docker_common_test.
case_start_announces() {
  setup; stub_dm Running
  sh "$CTL" start >/dev/null || fail "start exit 0"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "start must release op.lock when done"
  [ "$(sw)" = running ] || fail "start must announce the settled state"
  teardown
}

# CLI surface for resource_status(): docker-machine-ctl resource-status
# Prints three lines (memory_mib=N, vcpus=N, source=vmx|driver) or the single word unknown.
# Always exits 0 (even for unknown). Never calls start/stop/create/regenerate-certs/context-use.
case_resource_status() {
  setup
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  _vmx="$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"

  # Stub handles status + inspect format queries
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$*" in
  *Memory*) echo 2048 ;;
  *CPU*)    echo 2 ;;
  *status*) echo Running ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker-machine"

  # VMX source
  printf 'memsize = "2048"\nnumvcpus = "2"\n' > "$_vmx"
  out=$(sh "$CTL" resource-status)
  [ "$out" = "$(printf 'memory_mib=2048\nvcpus=2\nsource=vmx')" ] \
    || fail "resource-status VMX: got: $out"

  # Driver-only (no VMX)
  rm -f "$_vmx"
  out=$(sh "$CTL" resource-status)
  [ "$out" = "$(printf 'memory_mib=2048\nvcpus=2\nsource=driver')" ] \
    || fail "resource-status driver: got: $out"

  # Both sources invalid -> unknown, exit 0
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$*" in
  *Memory*|*CPU*) echo 0 ;;
  *status*)       echo Stopped ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker-machine"
  out=$(sh "$CTL" resource-status)
  [ "$out" = "unknown" ] || fail "resource-status unknown: got: $out"
  _rc=0; sh "$CTL" resource-status >/dev/null || _rc=$?
  [ "$_rc" -eq 0 ] || fail "resource-status unknown must exit 0, got: $_rc"

  # No forbidden dm calls, no op.lock created
  grep -qE '^(start|stop|create|regenerate-certs) ' "$DM_LOG" \
    && fail "resource-status must not call start/stop/create/regenerate-certs"
  grep -q 'context use' "$DM_LOG" \
    && fail "resource-status must not call context use"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] \
    && fail "resource-status must not create op.lock"

  # Stopped machine with creating.lock: lock preserved
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/creating.lock"
  sh "$CTL" resource-status >/dev/null
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/creating.lock" ] \
    || fail "resource-status must not remove creating.lock"

  teardown
}

case_status
case_start_stop
case_stop_marks_user_stopped
case_failed_stop_marks_nothing
case_up_verbs_clear_user_stopped
case_disk_status_ok
case_disk_status_low
case_disk_status_unknown
case_reclaimable
case_free_space
case_auto_free
case_auto_free_waits_for_op
case_disk_advice
case_enlarge_disk_plan
case_enlarge_disk
case_enlarge_disk_refusals
case_enlarge_disk_vdm_fails
case_readiness
case_readiness_hang_is_bounded
case_ensure_ready
case_repair
case_diagnostics
case_image
case_image_upgrade_fails
case_start_announces
case_no_room_to_boot
case_start_syncs_context
case_status_stays_fast
case_login
case_vmxpid
case_setup
case_packaging
case_release_concurrency
case_resource_status
case_overview_status
case_overview_api_hang_is_bounded
case_overview_dm_hang_is_bounded
case_start_clears_boot_refused
case_no_cache_files
echo "docker_ctl_test: OK"
