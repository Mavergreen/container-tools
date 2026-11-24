# platform: host-agnostic
# autosize.sh -- the Docker VM sizes itself (design, 2026-11-24). Sourced by docker-machine-common.sh.
# It starts small, grows under pressure (live when the provider can, else when no container is
# running or at the next start), and shrinks one step after 3 days of light use. It reaches the VM
# only through resize_vm and the provider's vm_* functions.

AUTOSIZE_WINDOW=${MAVERICKS_DOCKER_AUTOSIZE_WINDOW:-259200}     # 3 days of sampled time before a shrink
AUTOSIZE_COOLDOWN=${MAVERICKS_DOCKER_AUTOSIZE_COOLDOWN:-600}    # after a size change, nothing for 10 min
AUTOSIZE_STREAK=5                                               # ticks of pressure that make it sustained
AUTOSIZE_MIN_MB=1024

_as_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
_as_x100() { printf '%s\n' "$1" | awk '{ printf "%d", $1 * 100 + 0.5 }'; }   # "12.34" -> 1234
_as_mult4_up() { echo $(( ($1 + 3) / 4 * 4 )); }

# autosize_decide STATEFILE -- the policy, a pure function of the saved state and these variables:
#   sample   S_OOM S_PSWPIN S_MEMTOTAL_KB S_MEMAVAIL_KB S_LOAD5 S_PSI_MEM S_PSI_CPU (PSI empty when absent)
#   size     CUR_MB CUR_CPUS      limits  CEIL_MB CEIL_CPUS LIVE_CAP_MB (empty: no live cap)
#   time     NOW (epoch seconds)
# Rewrites STATEFILE and prints one line: none | grow MB CPUS live|restart | shrink MB CPUS |
# ceiling memory|cpus. Every step is measured from the current size. An unusable sample decides
# nothing and leaves the state as it was.
autosize_decide() {
  _f=$1
  for _v in "$S_MEMTOTAL_KB" "$S_MEMAVAIL_KB" "$S_OOM" "$S_PSWPIN" "$CUR_MB" "$CUR_CPUS" "$NOW"; do
    _as_int "$_v" || { echo none; return 0; }
  done
  _l5=$(_as_x100 "$S_LOAD5"); _as_int "$_l5" || { echo none; return 0; }
  a_t=; a_oom=0; a_pswpin=0; a_memhot=0; a_cpuhot=0; a_lowmem_s=0; a_lowcpu_s=0; a_peak_used_kb=0
  a_peak_load5=0; a_cool_until=0; a_size_mb=; a_size_cpus=; a_grown_mb=0; a_grown_cpus=0
  if [ -f "$_f" ]; then
    while read -r _k _val; do
      _as_int "$_val" || continue
      case "$_k" in
        t) a_t=$_val ;; oom) a_oom=$_val ;; pswpin) a_pswpin=$_val ;; memhot) a_memhot=$_val ;;
        cpuhot) a_cpuhot=$_val ;; lowmem_s) a_lowmem_s=$_val ;; lowcpu_s) a_lowcpu_s=$_val ;;
        peak_used_kb) a_peak_used_kb=$_val ;; peak_load5) a_peak_load5=$_val ;;
        cool_until) a_cool_until=$_val ;; size_mb) a_size_mb=$_val ;; size_cpus) a_size_cpus=$_val ;;
        grown_mb) a_grown_mb=$_val ;; grown_cpus) a_grown_cpus=$_val ;;
      esac
    done < "$_f"
  fi
  _out=none
  if [ -n "$a_t" ]; then
    _dt=$(( NOW - a_t )); [ "$_dt" -ge 0 ] || _dt=0; [ "$_dt" -le 300 ] || _dt=300
    _oomd=$(( S_OOM - a_oom )); _swd=$(( S_PSWPIN - a_pswpin ))   # negative: the VM restarted
    # A size change (ours, the user's, or a pending one applied) starts the cooldown and starts over.
    if [ "$a_size_mb" != "$CUR_MB" ] || [ "$a_size_cpus" != "$CUR_CPUS" ]; then
      a_cool_until=$(( NOW + AUTOSIZE_COOLDOWN )); a_memhot=0; a_cpuhot=0
      a_lowmem_s=0; a_lowcpu_s=0; a_peak_used_kb=0; a_peak_load5=0
    fi
    # Pressure: PSI when the kernel reports it, else swap-in and load. Memory stalls and swapping
    # count only while the VM as a whole is short (under 15% available): a container held to its own
    # memory limit stalls and swaps too, and growing the VM doesn't help it (review, 2026-11-24).
    _short=$(( S_MEMAVAIL_KB * 100 < S_MEMTOTAL_KB * 15 ))
    if [ -n "$S_PSI_MEM" ]; then _mh=$(( $(_as_x100 "$S_PSI_MEM") >= 1000 )); else _mh=$(( _swd >= 1000 )); fi
    _mh=$(( _mh && _short ))
    if [ -n "$S_PSI_CPU" ]; then _ch=$(( $(_as_x100 "$S_PSI_CPU") >= 5000 )); else _ch=$(( _l5 >= 150 * CUR_CPUS )); fi
    if [ "$_mh" = 1 ]; then a_memhot=$(( a_memhot + 1 )); else a_memhot=0; fi
    if [ "$_ch" = 1 ]; then a_cpuhot=$(( a_cpuhot + 1 )); else a_cpuhot=0; fi
    # Too large: under half the memory, and load under half of one fewer CPU, for sampled time.
    _used=$(( S_MEMTOTAL_KB - S_MEMAVAIL_KB ))
    if [ $(( _used * 2 )) -lt "$S_MEMTOTAL_KB" ]; then
      a_lowmem_s=$(( a_lowmem_s + _dt )); [ "$_used" -le "$a_peak_used_kb" ] || a_peak_used_kb=$_used
    else a_lowmem_s=0; a_peak_used_kb=0; fi
    if [ "$CUR_CPUS" -gt 1 ] && [ $(( _l5 * 2 )) -lt $(( 100 * (CUR_CPUS - 1) )) ]; then
      a_lowcpu_s=$(( a_lowcpu_s + _dt )); [ "$_l5" -le "$a_peak_load5" ] || a_peak_load5=$_l5
    else a_lowcpu_s=0; a_peak_load5=0; fi

    _wm=0; { [ "$_oomd" -gt 0 ] || [ "$a_memhot" -ge "$AUTOSIZE_STREAK" ]; } && _wm=1
    _wc=0; [ "$a_cpuhot" -ge "$AUTOSIZE_STREAK" ] && _wc=1
    if [ "$NOW" -lt "$a_cool_until" ]; then
      :
    elif [ "$_wm" = 1 ] || [ "$_wc" = 1 ]; then
      _nm=$CUR_MB; _nc=$CUR_CPUS
      if [ "$_wm" = 1 ] && [ "$CUR_MB" -lt "$CEIL_MB" ]; then
        _nm=$(( CUR_MB * 2 ))
        if _as_int "$LIVE_CAP_MB" && [ "$CUR_MB" -lt "$LIVE_CAP_MB" ] && [ "$_nm" -gt "$LIVE_CAP_MB" ]; then _nm=$LIVE_CAP_MB; fi
        [ "$_nm" -le "$CEIL_MB" ] || _nm=$(( CEIL_MB / 4 * 4 ))
      fi
      if [ "$_wc" = 1 ] && [ "$CUR_CPUS" -lt "$CEIL_CPUS" ]; then _nc=$(( CUR_CPUS + 1 )); fi
      if [ "$_nm" = "$CUR_MB" ] && [ "$_nc" = "$CUR_CPUS" ]; then
        if [ "$_wm" = 1 ]; then _out="ceiling memory"; else _out="ceiling cpus"; fi
      else
        _mode=live; _as_int "$LIVE_CAP_MB" && [ "$_nm" -gt "$LIVE_CAP_MB" ] && [ "$_nm" -gt "$CUR_MB" ] && _mode=restart
        _out="grow $_nm $_nc $_mode"; a_grown_mb=$_nm; a_grown_cpus=$_nc
      fi
      a_memhot=0; a_cpuhot=0
    else
      _nm=$CUR_MB; _nc=$CUR_CPUS
      if [ "$a_lowmem_s" -ge "$AUTOSIZE_WINDOW" ] && [ "$CUR_MB" -gt "$AUTOSIZE_MIN_MB" ]; then
        _nm=$(( CUR_MB / 2 / 4 * 4 ))
        _keep=$(_as_mult4_up $(( (a_peak_used_kb * 3 / 2 + 1023) / 1024 )))
        [ "$_nm" -ge "$_keep" ] || _nm=$_keep
        [ "$_nm" -ge "$AUTOSIZE_MIN_MB" ] || _nm=$AUTOSIZE_MIN_MB
        # Not below the size the last grow reached until 4 windows (12 days) pass quietly: the spike
        # that grew it happens between samples, and undoing it just to OOM again cycles.
        if [ "$a_lowmem_s" -lt $(( AUTOSIZE_WINDOW * 4 )) ] && [ "$_nm" -lt "$a_grown_mb" ]; then _nm=$a_grown_mb; fi
        [ "$_nm" -lt "$CUR_MB" ] || _nm=$CUR_MB
      fi
      if [ "$a_lowcpu_s" -ge "$AUTOSIZE_WINDOW" ] && [ "$CUR_CPUS" -gt 1 ]; then
        _nc=$(( CUR_CPUS - 1 ))
        if [ "$a_lowcpu_s" -lt $(( AUTOSIZE_WINDOW * 4 )) ] && [ "$_nc" -lt "$a_grown_cpus" ]; then _nc=$CUR_CPUS; fi
      fi
      if [ "$_nm" != "$CUR_MB" ] || [ "$_nc" != "$CUR_CPUS" ]; then _out="shrink $_nm $_nc"; fi
    fi
  fi
  { echo "t $NOW"; echo "oom $S_OOM"; echo "pswpin $S_PSWPIN"; echo "memhot $a_memhot"; echo "cpuhot $a_cpuhot"
    echo "lowmem_s $a_lowmem_s"; echo "lowcpu_s $a_lowcpu_s"; echo "peak_used_kb $a_peak_used_kb"
    echo "peak_load5 $a_peak_load5"; echo "cool_until $a_cool_until"; echo "size_mb $CUR_MB"; echo "size_cpus $CUR_CPUS"
    echo "grown_mb $a_grown_mb"; echo "grown_cpus $a_grown_cpus"
  } > "$_f.tmp" && mv -f "$_f.tmp" "$_f"
  echo "$_out"
}

# --- The login agent's side: sample, decide, act. -------------------------------------------------
AUTOSIZE_STATE="${STATE_DIR:-}/autosize-state"
AUTOSIZE_OFF="${STATE_DIR:-}/autosize-off"           # pinned: the user sized it, or turned self-sizing off
AUTOSIZE_PENDING="${STATE_DIR:-}/autosize-pending"   # "MB CPUS": a restart change, held until nothing runs
AUTOSIZE_DECIDED="${STATE_DIR:-}/autosize-decided"   # the first-run on/off decision was made
autosize_on() { [ ! -e "$AUTOSIZE_OFF" ]; }
# Existing VMs (maintainer's decision, 2026-11-24): one still at the default size self-sizes; one
# someone enlarged keeps its size, pinned, until they turn self-sizing on. Decided once.
autosize_first_decision() {
  [ -e "$AUTOSIZE_DECIDED" ] && return 0
  _fd=$(vm_size); _fm=${_fd% *}; _fc=${_fd#* }
  _as_int "$_fm" && _as_int "$_fc" || return 0   # no VM yet: decide when there is one
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if [ "$_fm" -gt "$AUTOSIZE_MIN_MB" ] || [ "$_fc" -gt 1 ]; then
    : > "$AUTOSIZE_OFF"; log "autosize: off for this VM, which someone sized at $_fm MB, $_fc CPUs (docker-machine-ctl autosize on)"
  else
    log "autosize: on for this VM ($_fm MB, $_fc CPUs)"
  fi
  : > "$AUTOSIZE_DECIDED"
}
# The user sized the VM themselves: self-sizing leaves it there until they turn it back on.
autosize_pin() { mkdir -p "$STATE_DIR" 2>/dev/null || true; : > "$AUTOSIZE_OFF"; : > "$AUTOSIZE_DECIDED"; rm -f "$AUTOSIZE_PENDING"; }
autosize_verb() { # on|off|status
  case "${1:-}" in
    on)  mkdir -p "$STATE_DIR" 2>/dev/null || true; rm -f "$AUTOSIZE_OFF"; : > "$AUTOSIZE_DECIDED"; echo on ;;
    off) autosize_pin; echo off ;;
    status) if autosize_on; then echo on; else echo off; fi
            if read -r _pm _pc 2>/dev/null < "$AUTOSIZE_PENDING"; then echo "pending $_pm $_pc"; fi ;;
    *) echo "usage: docker-machine-ctl autosize on|off|status" >&2; return 2 ;;
  esac
}
autosize_overview() { # the menu's lines
  autosize_first_decision   # the menu may ask before the login agent's first tick has decided
  if autosize_on; then echo "autosize on"; else echo "autosize off"; fi
  if read -r _pm _pc 2>/dev/null < "$AUTOSIZE_PENDING"; then echo "autosize-pending $_pm $_pc"; fi
  return 0
}
_as_now() { echo "${MAVERICKS_DOCKER_NOW:-$(date +%s)}"; }

# One ssh: the guest's counters as S_* assignments (KEY VALUE lines); nothing when it can't be read.
autosize_sample() {
  # The OOMs counted are the kernel log's global "Out of memory: Kill..." lines; a container killed at
  # its own memory limit logs "Memory cgroup out of memory" instead, and isn't the VM running out.
  # (/proc/vmstat's oom_kill counts both.)
  docker-machine ssh "$MACHINE" 'cat /proc/vmstat /proc/meminfo; echo "loadavg $(cat /proc/loadavg)"; for r in memory cpu; do sed -n "s/^some /psi_$r /p" /proc/pressure/$r 2>/dev/null; done; dmesg 2>/dev/null | grep "Out of memory: Kill"' 2>/dev/null \
    | awk '
      /\] Out of memory: Kill/ { o++; next }
      $1 == "pswpin"        { print "S_PSWPIN", $2 }
      $1 == "MemTotal:"     { print "S_MEMTOTAL_KB", $2 }
      $1 == "MemAvailable:" { print "S_MEMAVAIL_KB", $2 }
      $1 == "loadavg"       { print "S_LOAD5", $3 }
      $1 == "psi_memory" || $1 == "psi_cpu" {
        for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/^avg60=/, "", $i); print ($1 == "psi_memory" ? "S_PSI_MEM" : "S_PSI_CPU"), $i } }
      END { if (NR) print "S_OOM", o + 0 }'
}
# Self-sizing's ceiling: half the Mac's RAM, all its logical CPUs but one.
_as_ceiling() {
  _hb=$(sysctl -n hw.memsize 2>/dev/null); _hc=$(sysctl -n hw.logicalcpu 2>/dev/null)
  _as_int "$_hb" && CEIL_MB=$(( _hb / 1048576 / 2 / 4 * 4 )) || CEIL_MB=$CUR_MB
  _as_int "$_hc" && CEIL_CPUS=$(( _hc - 1 )) || CEIL_CPUS=$CUR_CPUS
  [ "$CEIL_CPUS" -ge 1 ] || CEIL_CPUS=1
}
_as_gb() { awk -v m="$1" 'BEGIN { g = m / 1024; if (g == int(g)) printf "%d", g; else printf "%.1f", g }'; }
# Nothing runs in Docker: docker answered, and listed no container.
_as_idle() { _ps=$(docker --context "$CONTEXT" ps -q 2>/dev/null) && [ -z "$_ps" ]; }
_as_apply_pending() { # the VM's state allows it; resize by restart to the held size
  read -r _pm _pc 2>/dev/null < "$AUTOSIZE_PENDING" || return 1
  log "autosize: applying the held change to $_pm MB, $_pc CPUs"
  if resize_vm --memory "$_pm" --cpus "$_pc" --restart >>"$LOG" 2>&1; then rm -f "$AUTOSIZE_PENDING"; return 0; fi
  log "autosize: the held change didn't apply"; return 1
}
# Before the VM starts or restarts (the login agent, ctl start/restart, the menu): at the held size.
autosize_apply_pending() { autosize_on && [ -f "$AUTOSIZE_PENDING" ] && _as_apply_pending; }
# Hold a grow to MB CPUS for a restart, merged with what's held already and the VM's size now (the
# bigger of each, so it never undoes a grow), unless the VM is already that big.
_as_hold() {
  _hm=$1; _hc=$2
  [ "$CUR_MB" -le "$_hm" ] || _hm=$CUR_MB; [ "$CUR_CPUS" -le "$_hc" ] || _hc=$CUR_CPUS
  if read -r _pm _pc 2>/dev/null < "$AUTOSIZE_PENDING"; then
    [ "$_pm" -le "$_hm" ] || _hm=$_pm; [ "$_pc" -le "$_hc" ] || _hc=$_pc
  fi
  if [ "$_hm" -le "$CUR_MB" ] && [ "$_hc" -le "$CUR_CPUS" ]; then rm -f "$AUTOSIZE_PENDING"; return 0; fi
  autosize_on || return 0   # the user pinned the size meanwhile
  echo "$_hm $_hc" > "$AUTOSIZE_PENDING"
}

autosize_tick() {
  autosize_first_decision
  autosize_on || return 0
  op_in_progress && return 0
  host_disk_full && return 0
  [ "$(machine_status)" = Running ] || return 0
  _smp=$(autosize_sample); [ -n "$_smp" ] || return 0
  S_OOM=; S_PSWPIN=; S_MEMTOTAL_KB=; S_MEMAVAIL_KB=; S_LOAD5=; S_PSI_MEM=; S_PSI_CPU=
  while read -r _k _val; do
    case "$_k" in
      S_OOM) S_OOM=$_val ;; S_PSWPIN) S_PSWPIN=$_val ;; S_MEMTOTAL_KB) S_MEMTOTAL_KB=$_val ;;
      S_MEMAVAIL_KB) S_MEMAVAIL_KB=$_val ;; S_LOAD5) S_LOAD5=$_val ;; S_PSI_MEM) S_PSI_MEM=$_val ;; S_PSI_CPU) S_PSI_CPU=$_val ;;
    esac
  done <<SAMPLE
$_smp
SAMPLE
  _sz=$(vm_size); CUR_MB=${_sz% *}; CUR_CPUS=${_sz#* }
  _as_int "$CUR_MB" && _as_int "$CUR_CPUS" || return 0
  _as_ceiling; LIVE_CAP_MB=$(vm_live_memory_max_mb); NOW=$(_as_now)
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  _d=$(autosize_decide "$AUTOSIZE_STATE")
  # A held change the facts have overtaken: a grow the VM already reached, a shrink under pressure.
  if read -r _pm _pc 2>/dev/null < "$AUTOSIZE_PENDING"; then
    if [ "$_pm" -le "$CUR_MB" ] && [ "$_pc" -le "$CUR_CPUS" ]; then
      log "autosize: dropped the held $_pm MB, $_pc CPUs: the VM is already that size or more"; rm -f "$AUTOSIZE_PENDING"
    elif { [ "$_pm" -lt "$CUR_MB" ] || [ "$_pc" -lt "$CUR_CPUS" ]; } && {
           case "$_d" in grow*|ceiling*) true ;; *) false ;; esac || grep -q -e '^memhot [1-9]' -e '^cpuhot [1-9]' "$AUTOSIZE_STATE"; }; then
      log "autosize: dropped the held shrink to $_pm MB, $_pc CPUs: the VM is busy again"; rm -f "$AUTOSIZE_PENDING"
    fi
  fi
  case "$_d" in
    "grow "*" live")
      set -- $_d; log "autosize: growing live to $2 MB, $3 CPUs (was $CUR_MB MB, $CUR_CPUS CPUs)"
      if _ro=$(resize_vm --memory "$2" --cpus "$3" 2>&1); then
        printf '%s\n' "$_ro" >>"$LOG"
        # A restart change held from before keeps what this grow added (never undoes it).
        if read -r _pm _pc 2>/dev/null < "$AUTOSIZE_PENDING"; then
          _sz=$(vm_size); CUR_MB=${_sz% *}; CUR_CPUS=${_sz#* }; _as_hold "$_pm" "$_pc"
        fi
      else
        printf '%s\n' "$_ro" >>"$LOG"
        case "$_ro" in
          *--restart*) log "autosize: this VM can't grow live now; holding $2 MB, $3 CPUs for a restart"; _as_hold "$2" "$3" ;;
          *) log "autosize: the live grow didn't take" ;;
        esac
      fi ;;
    "grow "*" restart")
      set -- $_d
      if [ -f "$AUTOSIZE_PENDING" ]; then
        notify autosize-pending "Container Tools for Mavericks" \
          "Docker needs more memory or CPUs; it resizes to $(_as_gb "$2") GB, $3 CPUs when no containers are running, or restart Docker now."
      fi
      log "autosize: holding a grow to $2 MB, $3 CPUs for a restart"; _as_hold "$2" "$3" ;;
    "shrink "*)
      set -- $_d
      if [ "$(cat "$AUTOSIZE_PENDING" 2>/dev/null)" != "$2 $3" ]; then
        log "autosize: holding a shrink to $2 MB, $3 CPUs for a restart (light use for days)"; fi
      autosize_on && echo "$2 $3" > "$AUTOSIZE_PENDING" ;;
    "ceiling memory")
      log "autosize: needs more memory than the ceiling ($CEIL_MB MB)"
      notify autosize-ceiling "Container Tools for Mavericks" \
        "Docker needs more memory than self-sizing allows ($(_as_gb "$CEIL_MB") GB). To give it more: docker-machine-ctl resize --memory MB --restart" ;;
    "ceiling cpus")
      log "autosize: needs more CPUs than the ceiling ($CEIL_CPUS)"
      notify autosize-ceiling "Container Tools for Mavericks" \
        "Docker needs more CPUs than self-sizing allows ($CEIL_CPUS). To give it more: docker-machine-ctl resize --cpus N --restart" ;;
  esac
  # A held change applies only once Docker has been quiet for two ticks running: no container listed
  # (a build between steps lists none, and BuildKit's never do), no pressure, light load.
  _quiet=0
  case "$_d" in none|shrink*)
    if ! grep -q -e '^memhot [1-9]' -e '^cpuhot [1-9]' "$AUTOSIZE_STATE" 2>/dev/null \
       && [ $(( S_MEMAVAIL_KB * 100 )) -ge $(( S_MEMTOTAL_KB * 15 )) ] \
       && [ "$(_as_x100 "$S_LOAD5")" -lt $(( 50 * CUR_CPUS )) ] && _as_idle; then _quiet=1; fi ;;
  esac
  if [ "$_quiet" = 1 ] && [ -f "$AUTOSIZE_PENDING" ]; then
    _qn=$(( $(cat "$STATE_DIR/autosize-quiet" 2>/dev/null || echo 0) + 1 ))
    if [ "$_qn" -ge 2 ]; then rm -f "$STATE_DIR/autosize-quiet"; _as_apply_pending || true
    else echo "$_qn" > "$STATE_DIR/autosize-quiet"; fi
  else
    rm -f "$STATE_DIR/autosize-quiet"
  fi
  return 0
}
