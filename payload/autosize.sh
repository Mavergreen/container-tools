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
  a_peak_load5=0; a_cool_until=0; a_size_mb=; a_size_cpus=
  if [ -f "$_f" ]; then
    while read -r _k _val; do
      _as_int "$_val" || continue
      case "$_k" in
        t) a_t=$_val ;; oom) a_oom=$_val ;; pswpin) a_pswpin=$_val ;; memhot) a_memhot=$_val ;;
        cpuhot) a_cpuhot=$_val ;; lowmem_s) a_lowmem_s=$_val ;; lowcpu_s) a_lowcpu_s=$_val ;;
        peak_used_kb) a_peak_used_kb=$_val ;; peak_load5) a_peak_load5=$_val ;;
        cool_until) a_cool_until=$_val ;; size_mb) a_size_mb=$_val ;; size_cpus) a_size_cpus=$_val ;;
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
    # Pressure: PSI when the kernel reports it, else swap-in and load.
    if [ -n "$S_PSI_MEM" ]; then _mh=$(( $(_as_x100 "$S_PSI_MEM") >= 1000 )); else _mh=$(( _swd >= 1000 )); fi
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
        _out="grow $_nm $_nc $_mode"
      fi
      a_memhot=0; a_cpuhot=0
    else
      _nm=$CUR_MB; _nc=$CUR_CPUS
      if [ "$a_lowmem_s" -ge "$AUTOSIZE_WINDOW" ] && [ "$CUR_MB" -gt "$AUTOSIZE_MIN_MB" ]; then
        _nm=$(( CUR_MB / 2 / 4 * 4 ))
        _keep=$(_as_mult4_up $(( (a_peak_used_kb * 3 / 2 + 1023) / 1024 )))
        [ "$_nm" -ge "$_keep" ] || _nm=$_keep
        [ "$_nm" -ge "$AUTOSIZE_MIN_MB" ] || _nm=$AUTOSIZE_MIN_MB
        [ "$_nm" -lt "$CUR_MB" ] || _nm=$CUR_MB
      fi
      if [ "$a_lowcpu_s" -ge "$AUTOSIZE_WINDOW" ] && [ "$CUR_CPUS" -gt 1 ]; then _nc=$(( CUR_CPUS - 1 )); fi
      if [ "$_nm" != "$CUR_MB" ] || [ "$_nc" != "$CUR_CPUS" ]; then _out="shrink $_nm $_nc"; fi
    fi
  fi
  { echo "t $NOW"; echo "oom $S_OOM"; echo "pswpin $S_PSWPIN"; echo "memhot $a_memhot"; echo "cpuhot $a_cpuhot"
    echo "lowmem_s $a_lowmem_s"; echo "lowcpu_s $a_lowcpu_s"; echo "peak_used_kb $a_peak_used_kb"
    echo "peak_load5 $a_peak_load5"; echo "cool_until $a_cool_until"; echo "size_mb $CUR_MB"; echo "size_cpus $CUR_CPUS"
  } > "$_f.tmp" && mv -f "$_f.tmp" "$_f"
  echo "$_out"
}
