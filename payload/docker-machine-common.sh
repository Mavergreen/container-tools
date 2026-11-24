#!/bin/sh
# platform: macOS-only -- osascript notifications and launchctl (lock ages read on BSD or GNU stat)
# docker-machine-common.sh — shared constants + helpers for docker-machine-bootstrap
# and docker-machine-ctl. SOURCED, not executed. Honors the MAVERICKS_DOCKER_* test seams.

# The menu-bar app (and anything else launched by LaunchServices) runs with a minimal PATH
# — /usr/bin:/bin:/usr/sbin:/sbin — that omits the install bindir. A bare `docker-machine`/
# `docker` then fails to resolve, so every verb driven from the GUI silently misreports:
# status_word() -> "absent" while the VM is really Stopped, and start/stop no-op. Guarantee
# our bindir is reachable regardless of the caller's PATH. Appended (not prepended) so a
# test/caller stub earlier on PATH still wins. Found dogfooding, 2026-07-29.
# CT_HOME is the tree, set by the script that sources this from its own location.
BINDIR=${MAVERICKS_DOCKER_BINDIR:-${CT_HOME:+$CT_HOME/bin}}
if [ -n "$BINDIR" ]; then
  case ":$PATH:" in *:"$BINDIR":*) ;; *) PATH="$PATH:$BINDIR"; export PATH ;; esac
fi

# Private test seams: a scratch VM (with its own DOCKER_CONFIG, so `docker context use` can't move
# the user's) proves VM-level verbs like enlarge-disk without touching the user's VM or context.
MACHINE=${MAVERICKS_DOCKER_MACHINE:-container-tools}
CONTEXT=${MAVERICKS_DOCKER_CONTEXT:-mavericks}
ISO=${MAVERICKS_DOCKER_ISO:-${CT_HOME:+$CT_HOME/share/boot2docker.iso}}
LOG=${MAVERICKS_DOCKER_LOG:-$HOME/Library/Logs/Mavergreen/container-tools/bootstrap.log}
STATE_DIR=${MAVERICKS_DOCKER_STATE_DIR:-$HOME/Library/Application Support/Mavergreen/container-tools}
LOCK="$STATE_DIR/creating.lock"
OP_LOCK="$STATE_DIR/op.lock"   # generic in-progress marker for the ctl verbs (start/stop/restart/image-upgrade)
USER_STOPPED="$STATE_DIR/user-stopped"   # the menu's Stop, for this boot: the login agent leaves the VM down
PROFILES=${MAVERICKS_DOCKER_PROFILES:-$HOME/.bash_profile $HOME/.profile $HOME/.zshrc $HOME/.bashrc}
AGENT_LABEL=dev.mavergreen.container-tools-machine
AGENT_PLIST=/Library/LaunchAgents/$AGENT_LABEL.plist
MACHDIR=${MAVERICKS_DOCKER_MACHDIR:-$HOME/.docker/machine/machines}

legacy_default_exists() { [ -d "$MACHDIR/default" ]; }

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null || true
}

notified_today() { # key  -- true when notify KEY already fired today, so its message needn't be built
  [ "$(cat "$STATE_DIR/notified-$1" 2>/dev/null)" = "$(date '+%Y-%m-%d')" ]
}

notify() { # key title message  (throttled once/day per key)
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  notified_today "$1" && return 0
  date '+%Y-%m-%d' > "$STATE_DIR/notified-$1" 2>/dev/null || true
  osascript -e "display notification \"$3\" with title \"$2\"" >/dev/null 2>&1 || true
}

fusion_present() {
  [ "${MAVERICKS_DOCKER_FUSION_PRESENT:-}" = 0 ] && return 1
  [ "${MAVERICKS_DOCKER_FUSION_PRESENT:-}" = 1 ] && return 0
  [ -d "/Applications/VMware Fusion.app" ] || command -v vmrun >/dev/null 2>&1
}

machine_status() { docker-machine status "$MACHINE" 2>/dev/null; }

# A path's mtime in epoch seconds. GNU's -c first: BSD stat (10.9's too) rejects -c and falls through
# to -f %m, while GNU's -f means filesystem status and would "succeed" with the wrong number.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

create_in_progress() {
  [ -d "$LOCK" ] || return 1
  _mt=$(_mtime "$LOCK") || return 0
  if [ $(( $(date +%s) - _mt )) -gt 600 ]; then
    log "stale create lock; reclaiming"
    rmdir "$LOCK" 2>/dev/null || true
    return 1
  fi
  return 0
}

# op.lock is the ctl verbs' in-progress marker, kept SEPARATE from creating.lock on purpose:
# the create path's atomic-acquire + interactive/migrate flows depend on creating.lock, and
# folding the two buys only conceptual unity. It records the pid that holds it, and that pid's
# liveness decides: an image-upgrade can legitimately outlast any fixed limit (2026-10-24: 15+ min,
# with VMware paused for host disk space), and the old 600s reclaim let the login agent's tick start
# the VM underneath it. A lock with no pid (taken by an older ctl) keeps the 600s age rule.
op_in_progress() {
  [ -d "$OP_LOCK" ] || return 1
  if _pid=$(cat "$OP_LOCK/pid" 2>/dev/null) && [ -n "$_pid" ]; then
    kill -0 "$_pid" 2>/dev/null && return 0
    log "op lock's owner (pid $_pid) is gone; reclaiming"
    rm -rf "$OP_LOCK" 2>/dev/null || true
    return 1
  fi
  _mt=$(_mtime "$OP_LOCK") || return 0
  if [ $(( $(date +%s) - _mt )) -gt 600 ]; then
    log "stale op lock; reclaiming"
    rm -rf "$OP_LOCK" 2>/dev/null || true
    return 1
  fi
  return 0
}

op_name() { cat "$OP_LOCK/name" 2>/dev/null || echo working; }

# The login agent re-runs bootstrap every 60s, and bootstrap starts any Stopped VM -- so without a
# record of intent, the menu's Stop was undone within a minute. ctl stop records it; every verb that
# brings the VM up clears it. Scoped to one boot (kern.boottime): after a reboot, "Start Docker at
# Login" means what it says again.
boot_id() { echo "${MAVERICKS_DOCKER_BOOT_ID:-$(sysctl -n kern.boottime 2>/dev/null)}"; }
mark_user_stopped() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  boot_id > "$USER_STOPPED" 2>/dev/null || true
}
clear_user_stopped() { rm -f "$USER_STOPPED" 2>/dev/null || true; }
user_stopped() { # true when the user stopped the VM during this boot; drops a marker from an earlier boot
  [ -f "$USER_STOPPED" ] || return 1
  [ "$(cat "$USER_STOPPED" 2>/dev/null)" = "$(boot_id)" ] && return 0
  log "user-stopped marker is from an earlier boot; auto-start resumes"
  clear_user_stopped
  return 1
}

op_begin() { # name  — announce a long op: create the lock, so the state reads working:<name>
  _op=${1:-working}   # tolerate a zero-arg call under the callers' `set -u`
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  mkdir "$OP_LOCK" 2>/dev/null || true  # portability-ok: runs only on the Mac (BSD mkdir is atomic)
  printf '%s\n' "$_op" > "$OP_LOCK/name" 2>/dev/null || true
  printf '%s\n' "$$" > "$OP_LOCK/pid" 2>/dev/null || true
  announce
}

# Like op_begin, but takes op.lock atomically and fails while another op holds it, for the ops that
# must never overlap one (auto-free, enlarge-disk). A dead owner's lock is reclaimed once.
op_try_begin() { # name
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if ! mkdir "$OP_LOCK" 2>/dev/null; then  # portability-ok: runs only on the Mac (BSD mkdir is atomic)
    op_in_progress && return 1
    mkdir "$OP_LOCK" 2>/dev/null || return 1  # portability-ok: runs only on the Mac (BSD mkdir is atomic)
  fi
  printf '%s\n' "$1" > "$OP_LOCK/name" 2>/dev/null || true
  printf '%s\n' "$$" > "$OP_LOCK/pid" 2>/dev/null || true
  announce
}

op_end() { # release the lock and tell the menu, which asks for the settled state itself
  rm -rf "$OP_LOCK" 2>/dev/null || true
  announce
}

vmx_pid() { pgrep -f "machines/$MACHINE/.*\.vmx" 2>/dev/null | head -1 || true; }

# Suspend stays allowed, and hard; hot-add is on. A soft suspend runs the guest's VMware Tools network
# script, which on boot2docker flushes every interface's address and can't restore it, so the VM
# resumes unreachable; that is why Wowfunhappy's docker-machine wrote suspend.disabled = "TRUE", and
# why every VM through 20261025.17 had it. A hard suspend skips the guest scripts and resumes intact
# (spike, 2026-11-24). Suspend must stay allowed, and mem/vcpu.hotadd on, because VMware hot-adds
# memory and CPUs (ctl resize, growing live) by a suspend-and-resume. components/docker-machine/
# patches/0002 and 0003 create VMs this way; this converts one created before them. Only while
# stopped and not suspended: Fusion reads the .vmx at power-on and may rewrite it while running, and a
# suspended VM resumes against the .vmx it was suspended with.
_VMX_READY='powerType.suspend = "hard"
mem.hotadd = "TRUE"
vcpu.hotadd = "TRUE"'
vmx_allows_hotadd() {
  _ah_vmx="$MACHDIR/$MACHINE/$MACHINE.vmx"
  [ -f "$_ah_vmx" ] || return 1
  grep -q '^suspend\.disabled *= *"TRUE"' "$_ah_vmx" && return 1
  grep -q '^powerType\.suspend *= *"hard"' "$_ah_vmx" && grep -q '^mem\.hotadd *= *"TRUE"' "$_ah_vmx" \
    && grep -q '^vcpu\.hotadd *= *"TRUE"' "$_ah_vmx"
}
prepare_vmx() {
  _pv_vmx="$MACHDIR/$MACHINE/$MACHINE.vmx"
  [ -f "$_pv_vmx" ] && [ -z "$(vmx_pid)" ] || return 0
  grep -q '^checkpoint\.vmState *= *"[^"]' "$_pv_vmx" && return 0
  vmx_allows_hotadd && return 0
  _pv_tmp="$_pv_vmx.ct-tmp"
  { awk '!/^suspend\.disabled *= *"TRUE"/ && !/^powerType\.suspend *=/ && !/^mem\.hotadd *=/ && !/^vcpu\.hotadd *=/' "$_pv_vmx"
    printf '%s\n' "$_VMX_READY"; } > "$_pv_tmp" && cat "$_pv_tmp" > "$_pv_vmx"   # cat keeps its mode
  rm -f "$_pv_tmp"
  log "prepared $_pv_vmx for hard suspend and hot-add"
}
# Every start of the VM goes through here (docker_common_test holds the payload to it).
machine_start() { prepare_vmx; docker-machine start "$MACHINE"; }

# VMware pauses the VM when the Mac's disk fills, and asks a noSpace (guest RAM's .vmem) or
# outofspace (the virtual disk) question in vmware.log once a second until it can carry on. Meanwhile
# docker-machine's status flaps and every docker-machine command waits, so this is the one thing
# worth telling the user. "Still asking" = the vmx is up and the log was written in the last 10s.
host_disk_full() {
  # "Still asking" is judged by the newest question's own timestamp, never the log's mtime: on
  # 2026-11-22 a question answered at 11:42 was still among the last 12 lines at 12:08, and an
  # unrelated line had just freshened the file, so the running VM read as paused. VMware stamps local
  # time; both sides are turned into seconds by plain awk arithmetic (no BSD/GNU date parsing).
  _vl="$MACHDIR/$MACHINE/vmware.log"
  [ -f "$_vl" ] && [ -n "$(vmx_pid)" ] || return 1
  _ts=$(tail -n 12 "$_vl" 2>/dev/null | grep -Ei 'nospace|outofspace' | tail -1 | cut -c1-19)
  [ -n "$_ts" ] || return 1
  printf '%s %s\n' "$_ts" "$(date '+%Y-%m-%dT%H:%M:%S')" | awk '
    function secs(t,  y, m, d) {   # days from civil (proleptic Gregorian), then seconds
      y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
      if (m <= 2) { y--; m += 12 }
      return ((365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d) * 86400 \
        + substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2))
    }
    { a = secs($1); n = secs($2); exit !(n - a >= -60 && n - a <= 10) }'
}

# Fusion backs guest RAM with a memsize-sized .vmem file in the VM's directory, allocated in full at
# every power-on; for a 16 GB VM, that file is what filled the Mac's disk on 2026-10-24. (Fusion 8.5
# for Mac reads mainMem.useNamedFile = "FALSE" and ignores it -- tried the same day.) So before
# powering on, require the .vmem's size plus 4 GB of headroom, and say what's needed when short:
# sets ROOM_MSG. A vmx we can't read memsize from doesn't block a start.
host_room_to_boot() {
  ROOM_MSG=
  _mb=$(sed -n 's/^memsize *= *"\([0-9]*\)".*/\1/p' "$MACHDIR/$MACHINE/$MACHINE.vmx" 2>/dev/null | head -1)
  [ -n "$_mb" ] || return 0
  _avail=$(df -k "$MACHDIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
  [ -n "$_avail" ] || return 0
  _need=$(( _mb * 1024 + 4 * 1024 * 1024 ))
  [ "$_avail" -ge "$_need" ] && return 0
  ROOM_MSG="Starting Docker needs about $(( (_need + 1048575) / 1048576 )) GB free on this Mac; $(( _avail / 1048576 )) GB free now."
  return 1
}

# The single word for the VM's state (the menu gets it through overview-status).
status_word() { _local_status || _status_from "$(machine_status)"; }
# What the Mac alone can tell, without asking docker-machine (which waits while VMware has the VM
# paused): prints the word and succeeds, or prints nothing and fails.
_local_status() {
  fusion_present || { echo no-fusion; return 0; }
  host_disk_full && { echo host-disk-full; return 0; }
  create_in_progress && { echo creating; return 0; }
  op_in_progress && { echo "working:$(op_name)"; return 0; }
  return 1
}
# The word for a docker-machine status, once _local_status had nothing to say. A boot the login
# agent refused for want of room is remembered in BOOT_REFUSED: nothing else can tell it from a
# plain stop, and the menu must keep saying why the VM is down.
_status_from() { # docker-machine status
  case "$1" in
    Running) echo running ;;
    Stopped) if [ -e "$BOOT_REFUSED" ]; then echo host-disk-full; else echo stopped; fi ;;
    "")      echo absent ;;
    *)       echo error ;;
  esac
}
BOOT_REFUSED="$STATE_DIR/boot-refused"   # the login agent refused to boot: the Mac lacks room (GB needed)
clear_boot_refused() { rm -f "$BOOT_REFUSED" 2>/dev/null || true; }

# The VM's disk, for the menu: "<total KB> <used KB> <avail KB> ok|low", or "unknown" when the VM is
# not running or df can't be read. Docker's data lives on /mnt/sda1. "low" is 90% used, counted the
# way df's Capacity is (used / (used + avail)). The disk filled silently once (2026-09-24: Linux
# 1Password's container crash-looped with ENOSPC and nothing on the Mac said why). Cached in
# Prints the line; the menu gets its own copy from overview-status.
disk_refresh() {
  _d=unknown
  if [ "$(machine_status)" = Running ]; then
    _d=$(docker-machine ssh "$MACHINE" df -P /mnt/sda1 2>/dev/null | awk '
      NR == 2 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $3 + $4 > 0 {
        printf "%s %s %s %s\n", $2, $3, $4, ($3 * 100 >= 90 * ($3 + $4)) ? "low" : "ok" }')
    [ -n "$_d" ] || _d=unknown
  fi
  printf '%s\n' "$_d"
}

# What a low disk gets without asking: only what is safe unattended. Dangling images (no -a, so
# never a tagged image, which may be impossible to rebuild) and build cache; never a container or
# a volume, which can hold the user's data. The menu's Free Up Space… still does the -a prune,
# after a confirmation. Takes op.lock atomically, so it never runs under a start, stop or upgrade,
# and fails if another op holds it. Records when it ran BEFORE pruning, so a failing prune is
# rate-limited too (auto_free_due).
AUTO_FREE_STAMP="$STATE_DIR/auto-free-last"
AUTO_FREE_EVERY=21600   # seconds: at most once every 6 hours
auto_free_due() {
  _last=$(cat "$AUTO_FREE_STAMP" 2>/dev/null) || return 0
  case "$_last" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $(date +%s) - _last )) -ge "$AUTO_FREE_EVERY" ]
}
auto_free_space() {
  op_try_begin auto-free || return 1
  date +%s > "$AUTO_FREE_STAMP" 2>/dev/null || true
  log "auto-free: disk is low; removing dangling images and build cache"
  _rc=0
  docker --context "$CONTEXT" image prune -f >>"$LOG" 2>&1 || _rc=$?
  docker --context "$CONTEXT" builder prune -f >>"$LOG" 2>&1 || _rc=$?
  log "auto-free: disk now $(disk_refresh)"
  op_end
  return $_rc
}

# When the disk is still low after auto-free, say what fills it and the action that fits, instead of
# always pointing at Free Up Space… (2026-11-20: volumes held 25 GB and Free Up Space… could free
# 0.7 GB). Weighs what can be freed (unused images, stopped containers), what the user's apps keep
# (volumes, never offered for deletion), and the largest container log (json-file logs have no cap
# by default). Below 1 GB everywhere, nothing large is left to free: suggest a bigger disk.
# Reports only. Docker prints sizes in decimal units (go-units: B kB MB GB TB).
_DISK_BYTES='function bytes(s,  n, u) { sub(/ .*/, "", s); n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
  return n * (u == "TB" ? 1e12 : u == "GB" ? 1e9 : u == "MB" ? 1e6 : (u == "kB" || u == "KB") ? 1e3 : 1) }'
_gb() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }
disk_advice() {
  _df=$(docker --context "$CONTEXT" system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)
  _img=$(printf '%s\n' "$_df" | awk -F'|' "$_DISK_BYTES"' $1 == "Images" { printf "%.0f", bytes($3) }')
  _ctr=$(printf '%s\n' "$_df" | awk -F'|' "$_DISK_BYTES"' $1 == "Containers" { printf "%.0f", bytes($3) }')
  _vol=$(printf '%s\n' "$_df" | awk -F'|' "$_DISK_BYTES"' $1 == "Local Volumes" { printf "%.0f", bytes($2) }')
  _bigvol=$(docker --context "$CONTEXT" system df -v 2>/dev/null | awk "$_DISK_BYTES"'
    /^Local Volumes space usage:/ { v = 1; next }
    v && /^VOLUME NAME/ { next }
    v && NF == 0 { if (seen) exit; next }
    v { seen = 1; b = bytes($NF); if (b > max) { max = b; name = $1 } }
    END { print name }')
  _log=$(docker-machine ssh "$MACHINE" "sudo sh -c 'du -sk /var/lib/docker/containers/*/*-json.log'" 2>/dev/null \
    | sort -rn | head -1)
  _logkb=${_log%%[!0-9]*}
  _logb=$(( ${_logkb:-0} * 1024 ))   # empty when no container has a log: never $(( * 1024 )), fatal to sh
  _logid=$(basename "$(dirname "${_log#*[ 	]}")" 2>/dev/null)
  _logname=$(docker --context "$CONTEXT" ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null \
    | awk -v id="$_logid" '$1 == id { print $2 }')
  _pre="The Docker VM's disk is almost full:"
  printf '%s\n' "img ${_img:-0}" "ctr ${_ctr:-0}" "vol ${_vol:-0}" "log ${_logb:-0}" | sort -k2 -rn | head -1 | {
    read -r _what _b
    if [ "${_b:-0}" -lt 1000000000 ]; then
      echo "$_pre nothing large is left to free. Choose Enlarge VM Disk… in the Container Tools menu."
    else case "$_what" in
      img) echo "$_pre unused images hold $(_gb "$_b"). Choose Free Up Space… in the Container Tools menu." ;;
      ctr) echo "$_pre stopped containers hold $(_gb "$_b"). See them with: docker ps -a -f status=exited" ;;
      vol) echo "$_pre volumes hold $(_gb "$_b"), the largest ${_bigvol:-unknown}. Clean up inside the app that uses it, or choose Enlarge VM Disk… in the Container Tools menu." ;;
      log) echo "$_pre the log of container ${_logname:-$_logid} is $(_gb "$_b"). Recreating the container clears it." ;;
    esac; fi
  }
}

# Enlarge the VM's disk in place, keeping images, volumes and containers: the procedure proven by
# hand on the owner's VM on 2026-11-21 (20 GB to 50 GB). Stop; grow the sparse vmdk with Fusion's
# vmware-vdiskmanager -x (GB there means GiB: 50GB became 104857600 sectors); start; then, online,
# grow sda1 to the new end (sfdisk also moves GPT's backup header there), tell the kernel (partx)
# and grow the ext4 (resize2fs). That only works because boot2docker puts swap first and the data
# partition sda1 last, so enlarge_plan checks it, along with everything else that would make the
# procedure unsafe, BEFORE anything is stopped. The vmdk grows on the Mac's disk only as the VM
# writes, but the Mac filling up is what pauses the VM, so the plan wants room for all of it.
VDISKMANAGER=${MAVERICKS_DOCKER_VDISKMANAGER:-/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager}
ENLARGE_BY_GB=20   # what the menu's Enlarge VM Disk… adds
enlarge_plan() { # [new GB]  -- prints "CUR_GB NEW_GB MAC_GB_NEEDED MAC_GB_FREE", or why not and fails
  _vmdk="$MACHDIR/$MACHINE/$MACHINE.vmdk"
  [ "$(machine_status)" = Running ] || { echo "Start Docker first, so the VM's disk layout can be checked."; return 1; }
  _hdr=$(head -c 2048 "$_vmdk" 2>/dev/null | LC_ALL=C tr -cd '[:print:]\n')
  case "$_hdr" in
    *'createType="monolithicSparse"'*) ;;
    *) echo "The VM's disk isn't a single sparse vmdk, so it can't be enlarged automatically."; return 1 ;;
  esac
  for _d in "$MACHDIR/$MACHINE/$MACHINE"-0*.vmdk; do
    [ -e "$_d" ] && { echo "The VM has a snapshot; delete it in VMware Fusion first."; return 1; }
  done
  _sec=$(printf '%s\n' "$_hdr" | sed -n 's/^RW \([0-9][0-9]*\) SPARSE.*/\1/p' | head -1)
  [ -n "$_sec" ] || { echo "Couldn't read the size of the VM's disk."; return 1; }
  _last=$(docker-machine ssh "$MACHINE" sudo sfdisk --dump /dev/sda 2>/dev/null | awk -F'[=,]' '
    /^\/dev\/sda[0-9]+ :/ { split($1, a, " "); s = $2 + 0; if (s > max) { max = s; dev = a[1] } }
    END { print dev }')
  [ "$_last" = /dev/sda1 ] || { echo "Docker's data partition isn't the last one on the VM's disk, so it can't be grown in place."; return 1; }
  _cur=$(( (_sec + 2097151) / 2097152 ))
  _new=${1:-$(( _cur + ENLARGE_BY_GB ))}
  case "$_new" in ''|*[!0-9]*) echo "Give the new size in whole GB."; return 1 ;; esac
  [ $(( _new * 2097152 )) -gt "$_sec" ] || { echo "The VM's disk is already $_cur GB; give a bigger size."; return 1; }
  _need=$(( ((_new * 2097152 - _sec) * 512 + 1073741823) / 1073741824 + 4 ))
  _avail=$(df -k "$MACHDIR" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }')
  [ "${_avail:-0}" -ge "$_need" ] || { echo "Enlarging the VM's disk to $_new GB needs about $_need GB free on this Mac; ${_avail:-0} GB free now."; return 1; }
  echo "$_cur $_new $_need $_avail"
}
enlarge_disk() { # [new GB]
  op_try_begin enlarge-disk || { echo "Another Docker operation is running; try again when it finishes."; return 1; }
  if ! _plan=$(enlarge_plan "${1:-}"); then
    log "enlarge-disk refused: $_plan"; echo "$_plan"; op_end; return 1
  fi
  _new=$(echo "$_plan" | awk '{ print $2 }')
  log "enlarge-disk: $(echo "$_plan" | awk '{ print $1 }') GB -> $_new GB"
  docker-machine stop "$MACHINE" >>"$LOG" 2>&1 || true
  _i=0; while [ -n "$(vmx_pid)" ] && [ "$_i" -lt 120 ]; do sleep 1; _i=$(( _i + 1 )); done
  _rc=0
  if [ -n "$(vmx_pid)" ]; then
    log "enlarge-disk: the VM didn't stop; its disk was not touched"; _rc=1
  elif ! "$VDISKMANAGER" -x "${_new}GB" "$MACHDIR/$MACHINE/$MACHINE.vmdk" >>"$LOG" 2>&1; then
    log "enlarge-disk: vmware-vdiskmanager failed; the disk is unchanged"; _rc=1
  fi
  machine_start >>"$LOG" 2>&1 || true   # always bring the VM back up
  if [ "$(machine_status)" = Running ]; then
    sync_context
    if [ "$_rc" -eq 0 ] && ! docker-machine ssh "$MACHINE" \
        "sudo sh -c 'echo ,+ | sfdisk --no-reread -N 1 /dev/sda && partx -u /dev/sda && resize2fs /dev/sda1'" >>"$LOG" 2>&1; then
      log "enlarge-disk: the vmdk is now $_new GB but growing sda1 failed; finish by hand with: docker-machine ssh $MACHINE \"sudo sh -c 'echo ,+ | sfdisk --no-reread -N 1 /dev/sda && partx -u /dev/sda && resize2fs /dev/sda1'\""
      _rc=1
    fi
  else
    log "enlarge-disk: the VM didn't come back up"; _rc=1
  fi
  _d=$(disk_refresh); log "enlarge-disk: disk now $_d"
  op_end
  echo "$_d"   # last line: the new disk, for the menu's toast
  return $_rc
}

# Readiness, version 1 (2026-11-22). "running" is the VM's power; ready means Docker itself answers:
# the managed context, with inherited endpoint/TLS overrides cleared, completes an authenticated API
# call. Consumers (Porthole's launchers, the op CLI, the menu) ask this instead of trusting power.
# States: ready | finishing-setup (running, API not answering yet) | needs-attention (TLS the
# context can't verify: Repair) | any other status_word (stopped, absent, creating, working:<op>,
# no-fusion, host-disk-full, error). Nothing here repairs: regenerating certs restarts the daemon,
# so that only happens when someone chooses Repair. The every-install cause of an unverifiable
# daemon (create aborting before provisioning) is fixed in docker-machine itself (patch 0001).
READINESS_VERSION=1
API_ERR_FILE="$STATE_DIR/api-error" # the latest API probe's stderr, for diagnostics
_with_timeout() { # secs cmd...  -- run cmd; kill it after secs (exit 124). No GNU timeout on 10.9.
  _s=$1; shift
  # The killer marks a timeout in a flag file before it kills, so a slow kill can't be mistaken for
  # the command finishing. It kills the command's children too (docker-machine's vmrun or ssh), or
  # each timeout would leave one orphaned; and its own sleep is killed when the command finishes first.
  _tf=$(mktemp "${TMPDIR:-/tmp}/ct-timeout.XXXXXX" 2>/dev/null) && rm -f "$_tf" || _tf=
  "$@" & _p=$!
  ( trap 'kill "$_sl" 2>/dev/null; exit 0' TERM
    sleep "$_s" & _sl=$!; wait "$_sl"
    [ -z "$_tf" ] || : > "$_tf"; pkill -P "$_p"; kill "$_p" ) >/dev/null 2>&1 </dev/null & _k=$!
  wait "$_p"; _r=$?
  kill "$_k" 2>/dev/null; wait "$_k" 2>/dev/null
  if [ -n "$_tf" ]; then
    [ -e "$_tf" ] && { rm -f "$_tf"; _r=124; }
  elif [ "$_r" -eq 143 ]; then _r=124; fi
  return $_r
}
api_state() { # secs  -- for a running VM: ready | finishing-setup | needs-attention
  # Into files, not a $(...) pipe: a timed-out process's leftover child would hold a pipe open and
  # make the caller wait anyway.
  # Per-call files: the tick, a launcher and the menu's diagnostics can all probe at once.
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  _o=$(mktemp "$STATE_DIR/api-out.XXXXXX") || _o=/dev/null
  _e=$(mktemp "$STATE_DIR/api-err.XXXXXX") || _e=/dev/null
  (unset DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_CONTEXT DOCKER_API_VERSION
   _with_timeout "$1" docker --context "$CONTEXT" info --format '{{.ServerVersion}}') \
    >"$_o" 2>"$_e" </dev/null
  _r=$?
  _v=$(cat "$_o" 2>/dev/null); [ "$_o" = /dev/null ] || rm -f "$_o"
  [ "$_r" -ne 124 ] || echo "no answer from Docker within $1 s" >> "$_e"
  if [ "$_r" -eq 0 ] && [ -n "$_v" ]; then _a=ready
  elif grep -q -e 'unknown authority' -e 'certificate is valid for' "$_e" 2>/dev/null; then _a=needs-attention
  else _a=finishing-setup; fi
  [ "$_e" = /dev/null ] || mv -f "$_e" "$API_ERR_FILE" 2>/dev/null || rm -f "$_e"
  echo "$_a"
}
# docker-machine status, given up after secs (prints "timeout"): a wedged VM makes every
# docker-machine command wait. Into a file, not a $(...) pipe, as in api_state.
machine_status_bounded() { # secs
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  _mo=$(mktemp "$STATE_DIR/ms-out.XXXXXX") || { machine_status; return; }
  _with_timeout "$1" docker-machine status "$MACHINE" >"$_mo" 2>/dev/null </dev/null
  if [ $? -eq 124 ]; then echo timeout; else cat "$_mo"; fi
  rm -f "$_mo"
}
# The VM disk line, as disk_refresh reads it, given up after secs (prints nothing then).
_disk_line() { # secs
  _do=$(mktemp "$STATE_DIR/disk-out.XXXXXX") || return 0
  _with_timeout "$1" docker-machine ssh "$MACHINE" df -P /mnt/sda1 >"$_do" 2>/dev/null </dev/null
  _dr=$?
  awk '
    NR == 2 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $3 + $4 > 0 {
      printf "%s %s %s %s\n", $2, $3, $4, ($3 * 100 >= 90 * ($3 + $4)) ? "low" : "ok" }' "$_do"
  rm -f "$_do"
  [ "$_dr" -ne 124 ] || echo timeout
}
# Everything the menu shows, in one call bounded to about 5 s, as "key value" lines after a version
# line. The menu renders this and adds nothing of its own. "state" folds readiness into running
# (finishing-setup / needs-attention). Docker and the VM's disk are asked only when the VM is up and
# no op holds it; an omitted line means "keep what you had". The VM's disk (an ssh round trip) and
# the image (hashing two ISOs) change slowly, so a running VM's disk line and the image line come
# only with --full, which the menu asks for on its slow cadence, not every 2 s. A quick call takes
# 1-2 s on an idle 10.9 box; --full takes 5-10 s, more under load.
OVERVIEW_VERSION=1
overview_status() { # [--full]
  rm -f "$STATE_DIR/state" "$STATE_DIR/readiness" "$STATE_DIR/disk" 2>/dev/null || true   # pre-overview caches
  # The local checks first: a paused VM or a running op must not wait on docker-machine.
  # Its status takes ~1 s, but a cold first call on 10.9 can take 3+.
  _w=$(_local_status) || _w=$(_status_from "$(machine_status_bounded 5)")
  _disk=
  case "$_w" in
    running)
      _a=$(api_state 5); [ "$_a" = ready ] || _w=$_a   # a cold docker info on 10.9 can take 3+ s
      if [ "${1:-}" = --full ]; then   # a read that timed out leaves the line out: keep the last value
        _disk=$(_disk_line 4); case "$_disk" in "") _disk=unknown ;; timeout) _disk= ;; esac
      fi ;;
    working:*|creating) ;;
    *) _disk=unknown ;;
  esac
  echo "version $OVERVIEW_VERSION"
  echo "state $_w"
  [ -z "$_disk" ] || echo "disk $_disk"
  _v=$(vmx_pid); echo "vmx-pid ${_v:-0}"
  if launchctl list "$AGENT_LABEL" >/dev/null 2>&1; then echo "login on"; else echo "login off"; fi
  [ "${1:-}" != --full ] || echo "image $(image_status)"
}
readiness_state() { # [secs]
  _w=$(status_word)
  if [ "$_w" = running ]; then api_state "${1:-10}"; else echo "$_w"; fi
}
# Bring Docker to ready within secs, or say why not (exit 124 when the budget ran out). Starts a
# stopped VM once, through the same noninteractive bootstrap the login agent runs, unless the user
# stopped it this boot. It never creates an absent VM (that's `setup`, minutes long, and killing a
# create partway is exactly what leaves a VM nothing can verify). A start, once begun, is let finish
# rather than killed, so the budget bounds the waiting, not a start already under way.
# needs-attention won't fix itself, so it returns at once instead of waiting out the budget.
ensure_ready() { # secs
  _end=$(( $(date +%s) + $1 )); _booted=no; _next_sync=0
  # A boot the login agent refused earlier: retry now if the Mac has room again, not at its next tick.
  if [ -e "$BOOT_REFUSED" ] && host_room_to_boot; then clear_boot_refused; fi
  while :; do
    _w=$(status_word)
    case "$_w" in
      absent) echo absent; return 1 ;;
      stopped)
        if user_stopped; then echo stopped; return 1; fi
        if [ "$_booted" = no ]; then
          _booted=yes
          MAVERICKS_DOCKER_NONINTERACTIVE=1 docker-machine-bootstrap >>"$LOG" 2>&1 || true
          continue
        fi ;;
      running)
        if [ "$(date +%s)" -ge "$_next_sync" ]; then sync_context; _next_sync=$(( $(date +%s) + 10 )); fi
        _left=$(( _end - $(date +%s) )); [ "$_left" -ge 1 ] || _left=1; [ "$_left" -le 10 ] || _left=10
        _w=$(api_state "$_left")
        case "$_w" in
          ready) echo ready; return 0 ;;
          needs-attention) echo needs-attention; return 1 ;;
        esac ;;
      no-fusion|host-disk-full|error) echo "$_w"; return 1 ;;
    esac
    [ "$(date +%s)" -lt "$_end" ] || { echo "$_w"; return 124; }
    sleep 1
  done
}
# Repair, chosen by the user: bring the VM up, re-point the context, and only when the daemon's TLS
# can't be verified, regenerate the machine's server certificates (`regenerate-certs -f`, the fix
# measured on the 2026-11-11 repave). Never --client-certs (that rotates the client identity every
# consumer shares), never removes or recreates the VM or its data. Then waits up to 60 s for ready.
repair() {
  op_try_begin repair || { echo "Another Docker operation is running; try again when it finishes."; return 1; }
  clear_user_stopped
  [ "$(machine_status)" = Running ] || machine_start >>"$LOG" 2>&1 || true
  sync_context
  if [ "$(api_state 10)" = needs-attention ]; then
    log "repair: $(tr '\n' ' ' < "$API_ERR_FILE" 2>/dev/null); regenerating $MACHINE's certificates"
    docker-machine regenerate-certs -f "$MACHINE" >>"$LOG" 2>&1 || true
    sync_context
  fi
  op_end
  _w=$(ensure_ready 60); _r=$?
  announce
  log "repair: $_w"
  echo "$_w"
  return $_r
}
diagnostics() {
  echo "readiness: $(readiness_state 5)"
  echo "power: $(machine_status || true)"
  echo "status: $(status_word)"
  echo "context $CONTEXT: $(docker context inspect "$CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
  echo "machine endpoint: $(docker-machine url "$MACHINE" 2>/dev/null)"
  echo "last API error: $(head -c 400 "$API_ERR_FILE" 2>/dev/null | tr '\n' ' ')"
  user_stopped && echo "stopped by the user this boot: yes"
  op_in_progress && echo "operation in progress: $(op_name)"
  echo "log: $LOG"
}

# Tell the menu-bar app something changed; it asks overview-status for the rest. A Darwin
# notification, so nothing is cached on disk to go stale. No notifyutil (Linux CI): nothing to tell.
NOTIFY_NAME=dev.mavergreen.container-tools.changed
announce() {
  command -v notifyutil >/dev/null 2>&1 || return 0
  notifyutil -p "$NOTIFY_NAME" >/dev/null 2>&1 || true
}

# Re-point the 'mavericks' docker context at the VM's current endpoint, healing the two ways a
# DHCP renumber breaks it: a stale context host (so `docker` doesn't hang on the dead IP) and a
# TLS cert issued for the old IP. Detection uses `docker-machine env`, which reads docker-machine's
# OWN current-IP knowledge -- so it never hangs on the stale context. Cert regen is gated to that
# specific error only (regenerate-certs restarts the daemon, so never for transient/unreachable
# failures). Found dogfooding the default->container-tools migration, 2026-07-27. Shared by
# docker-machine-bootstrap (timer/login) and docker-machine-ctl (start/restart/status).
sync_context() {
  _env=$(docker-machine env "$MACHINE" 2>/dev/null)
  if [ -z "$_env" ] && docker-machine env "$MACHINE" 2>&1 | grep -q 'certificate is valid for'; then
    log "cert/IP mismatch on $MACHINE (a rename gave it a new IP); regenerating certs"
    docker-machine regenerate-certs -f "$MACHINE" >>"$LOG" 2>&1 || true
    _env=$(docker-machine env "$MACHINE" 2>/dev/null)
  fi
  [ -n "$_env" ] || return 0
  DOCKER_HOST=; DOCKER_CERT_PATH=
  eval "$_env" 2>/dev/null || return 0
  [ -n "${DOCKER_HOST:-}" ] || return 0
  _spec="host=$DOCKER_HOST,ca=$DOCKER_CERT_PATH/ca.pem,cert=$DOCKER_CERT_PATH/cert.pem,key=$DOCKER_CERT_PATH/key.pem"
  if docker context inspect "$CONTEXT" >/dev/null 2>&1; then
    _cur=$(docker context inspect "$CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
    if [ "$_cur" != "$DOCKER_HOST" ]; then
      docker context update "$CONTEXT" --docker "$_spec" >>"$LOG" 2>&1 || true
      log "context host -> $DOCKER_HOST"
    fi
  else
    docker context create "$CONTEXT" --docker "$_spec" >>"$LOG" 2>&1 || true
    log "context created -> $DOCKER_HOST"
  fi
  docker context use "$CONTEXT" >>"$LOG" 2>&1 || true
}

# A host copies boot2docker.iso at `docker-machine create` and boots that copy forever, so a package
# update that refreshes $ISO doesn't reach the VM until `docker-machine upgrade`. Compare the VM's
# booted image to the freshly-installed one. Echoes current | stale | absent (no VM / no installed
# ISO to compare). Pure CLI -- the menu-bar app and a human at a shell both call it.
image_status() {
  _mi="$MACHDIR/$MACHINE/boot2docker.iso"
  [ -f "$_mi" ] && [ -f "$ISO" ] || { echo absent; return; }
  if [ "$(shasum -a 256 "$_mi" 2>/dev/null | awk '{print $1}')" = "$(shasum -a 256 "$ISO" 2>/dev/null | awk '{print $1}')" ]; then
    echo current
  else
    echo stale
  fi
}

# Point the VM's Boot2DockerURL at the installed ISO. A Wowfunhappy-migrated host still holds the old
# DMG path (/Volumes/Docker for Mavericks/...), gone after unmount, so `docker-machine upgrade` fails
# fetching it. Unconditional and idempotent -- a no-op for a host already on the installed image.
repoint_iso_url() {
  _cfg="$MACHDIR/$MACHINE/config.json"
  # -i.bak, not -i '': the one in-place form BSD sed (10.9's too) and GNU sed both read the same way.
  { [ -f "$_cfg" ] && sed -i.bak "s|\"Boot2DockerURL\": *\"[^\"]*\"|\"Boot2DockerURL\": \"$ISO\"|" "$_cfg" 2>/dev/null \
      && rm -f "$_cfg.bak"; } || true
}

# Read the VM's configured RAM and CPU from the VMX file (memsize/numvcpus) when both are
# valid positive integers; otherwise fall back to the docker-machine driver JSON (Driver.Memory /
# Driver.CPU). Never combine values from different sources. Print:
#   memory_mib=N
#   vcpus=N
#   source=vmx|driver
# or the single word "unknown" when no source has a complete valid pair. Exit 0 always.
# Read-only: never writes VMX, never starts/stops/creates the VM, never changes context.
resource_status() {
  _rs_vmx="$MACHDIR/$MACHINE/$MACHINE.vmx"
  _rs_mem=$(sed -n 's/^memsize *= *"\([0-9]*\)".*/\1/p' "$_rs_vmx" 2>/dev/null | head -1)
  _rs_cpu=$(sed -n 's/^numvcpus *= *"\([0-9]*\)".*/\1/p' "$_rs_vmx" 2>/dev/null | head -1)
  if [ -n "$_rs_mem" ] && [ "$_rs_mem" -gt 0 ] 2>/dev/null \
  && [ -n "$_rs_cpu" ] && [ "$_rs_cpu" -gt 0 ] 2>/dev/null; then
    printf 'memory_mib=%s\nvcpus=%s\nsource=vmx\n' "$_rs_mem" "$_rs_cpu"
    return
  fi
  _rs_mem=$(docker-machine inspect "$MACHINE" --format '{{.Driver.Memory}}' 2>/dev/null)
  _rs_cpu=$(docker-machine inspect "$MACHINE" --format '{{.Driver.CPU}}' 2>/dev/null)
  if [ -n "$_rs_mem" ] && [ "$_rs_mem" -gt 0 ] 2>/dev/null \
  && [ -n "$_rs_cpu" ] && [ "$_rs_cpu" -gt 0 ] 2>/dev/null; then
    printf 'memory_mib=%s\nvcpus=%s\nsource=driver\n' "$_rs_mem" "$_rs_cpu"
    return
  fi
  echo unknown
}
