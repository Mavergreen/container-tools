#!/bin/sh
# platform: host-agnostic
# autosize_decide: the self-sizing policy, a pure function of the saved state, one sample of the
# guest, the VM's size, the ceiling and the provider's live cap (design, 2026-11-24).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
A="$ROOT/payload/autosize.sh"
fail() { echo "autosize_policy_test: FAIL: $*" >&2; exit 1; }
[ -f "$A" ] || fail "no payload/autosize.sh"

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/autosize-policy.XXXXXX"); F="$WORK/state"
  unset MAVERICKS_DOCKER_AUTOSIZE_WINDOW MAVERICKS_DOCKER_AUTOSIZE_COOLDOWN 2>/dev/null || true
  # A quiet 1 GB / 1 CPU guest on an 8-CPU, 16 GB Mac; the VM booted small (live cap 3 GB).
  S_OOM=0 S_PSWPIN=0 S_MEMTOTAL_KB=962560 S_MEMAVAIL_KB=600000 S_LOAD5=0.10 S_PSI_MEM= S_PSI_CPU=
  CUR_MB=1024 CUR_CPUS=1 CEIL_MB=8192 CEIL_CPUS=7 LIVE_CAP_MB=3072 NOW=1000000
}
teardown() { rm -rf "$WORK"; }
decide() {
  ( S_OOM=$S_OOM S_PSWPIN=$S_PSWPIN S_MEMTOTAL_KB=$S_MEMTOTAL_KB S_MEMAVAIL_KB=$S_MEMAVAIL_KB \
    S_LOAD5=$S_LOAD5 S_PSI_MEM=$S_PSI_MEM S_PSI_CPU=$S_PSI_CPU CUR_MB=$CUR_MB CUR_CPUS=$CUR_CPUS \
    CEIL_MB=$CEIL_MB CEIL_CPUS=$CEIL_CPUS LIVE_CAP_MB=$LIVE_CAP_MB NOW=$NOW; . "$A"; autosize_decide "$F" )
}
tick() { NOW=$(( NOW + 60 )); decide; }   # one login-agent tick later
key() { sed -n "s/^$1 //p" "$F"; }

case_first_sample_records_only() {
  setup
  [ "$(decide)" = none ] || fail "a first sample only records"
  [ "$(key oom)" = 0 ] && [ "$(key t)" = "$NOW" ] || fail "the state records the counters and the time: $(cat "$F")"
  teardown
}
case_oom_grows_now() {
  setup; decide >/dev/null; S_OOM=1
  r=$(tick); [ "$r" = "grow 2048 1 live" ] || fail "an OOM kill grows memory at once (got $r)"
  teardown
}
case_double_clamps_to_live_cap() {
  setup; CUR_MB=2048; decide >/dev/null; S_OOM=1
  r=$(tick); [ "$r" = "grow 3072 1 live" ] || fail "a double past the live cap grows live to the cap (got $r)"
  teardown
}
case_past_cap_is_restart() {
  setup; CUR_MB=3072; decide >/dev/null; S_OOM=1
  r=$(tick); [ "$r" = "grow 6144 1 restart" ] || fail "growing past the live cap is a restart change (got $r)"
  teardown
}
case_no_cap_grows_live() {
  setup; CUR_MB=4096; LIVE_CAP_MB=; decide >/dev/null; S_OOM=1
  r=$(tick); [ "$r" = "grow 8192 1 live" ] || fail "with no cap, a grow is live (got $r)"
  teardown
}
case_psi_memory_sustained() {
  setup; S_PSI_MEM=0.00; S_PSI_CPU=0.00; decide >/dev/null; S_PSI_MEM=12.50
  for i in 1 2 3 4; do r=$(tick); [ "$r" = none ] || fail "tick $i of pressure is not yet sustained (got $r)"; done
  r=$(tick); [ "$r" = "grow 2048 1 live" ] || fail "5 ticks of memory pressure grow memory (got $r)"
  teardown
}
case_swapin_fallback() {
  setup; decide >/dev/null
  for i in 1 2 3 4; do S_PSWPIN=$(( S_PSWPIN + 1500 )); r=$(tick); [ "$r" = none ] || fail "swap tick $i (got $r)"; done
  S_PSWPIN=$(( S_PSWPIN + 1500 )); r=$(tick); [ "$r" = "grow 2048 1 live" ] || fail "5 ticks of swapping grow memory (got $r)"
  teardown
}
case_cpu_sustained() {
  setup; decide >/dev/null; S_LOAD5=2.00
  for i in 1 2 3 4; do r=$(tick); [ "$r" = none ] || fail "load tick $i (got $r)"; done
  r=$(tick); [ "$r" = "grow 1024 2 live" ] || fail "5 ticks of load grow a CPU (got $r)"
  teardown
}
case_psi_cpu_sustained() {
  setup; S_PSI_MEM=0.00; S_PSI_CPU=0.00; decide >/dev/null; S_PSI_CPU=60.00; S_LOAD5=0.50
  for i in 1 2 3 4; do tick >/dev/null; done
  r=$(tick); [ "$r" = "grow 1024 2 live" ] || fail "5 ticks of CPU pressure grow a CPU (got $r)"
  teardown
}
case_streak_breaks() {
  setup; decide >/dev/null; S_LOAD5=2.00
  for i in 1 2 3 4; do tick >/dev/null; done
  S_LOAD5=0.10; tick >/dev/null; S_LOAD5=2.00
  for i in 1 2 3 4; do r=$(tick); [ "$r" = none ] || fail "a broken streak starts over (got $r)"; done
  teardown
}
case_cooldown() {
  setup; decide >/dev/null; printf 'cool_until %s\n' $(( NOW + 200 )) >> "$F"; S_OOM=1
  r=$(tick); [ "$r" = none ] || fail "nothing changes during the cooldown (got $r)"
  teardown
}
case_size_change_starts_cooldown() {
  setup; decide >/dev/null; CUR_MB=2048; tick >/dev/null; S_OOM=1
  r=$(tick); [ "$r" = none ] || fail "a size change starts the 10-minute cooldown (got $r)"
  NOW=$(( NOW + 600 )); S_OOM=2; r=$(decide); [ "$r" = "grow 3072 1 live" ] || fail "after the cooldown it grows again (got $r)"
  teardown
}
case_at_ceiling() {
  setup; CUR_MB=8192; CUR_CPUS=7; LIVE_CAP_MB=; decide >/dev/null; S_OOM=1
  r=$(tick); [ "$r" = "ceiling memory" ] || fail "pressure at the ceiling is reported, not acted on (got $r)"
  teardown
}
case_ceiling_clamps() {
  setup; CUR_MB=6144; LIVE_CAP_MB=; decide >/dev/null; S_OOM=1
  r=$(tick); [ "$r" = "grow 8192 1 live" ] || fail "a double past the ceiling stops at it (got $r)"
  teardown
}
case_shrink_after_3_days() {
  setup; CUR_MB=4096; CUR_CPUS=2; LIVE_CAP_MB=; S_MEMTOTAL_KB=3850000; S_MEMAVAIL_KB=2750000   # ~1.05 GB used
  decide >/dev/null
  r=$(tick); [ "$r" = none ] || fail "one quiet minute is not 3 days (got $r)"
  sed -e 's/^lowmem_s .*/lowmem_s 259100/' -e 's/^lowcpu_s .*/lowcpu_s 259100/' "$F" > "$F.t" && mv "$F.t" "$F"
  NOW=$(( NOW + 300 )); r=$(decide); [ "$r" = "shrink 2048 1" ] || fail "3 quiet days shrink one step (got $r; $(cat "$F"))"
  teardown
}
case_shrink_keeps_headroom() {
  setup; CUR_MB=8192; LIVE_CAP_MB=; S_MEMTOTAL_KB=7900000; S_MEMAVAIL_KB=4500000   # ~3.3 GB used, under half
  decide >/dev/null; sed 's/^lowmem_s .*/lowmem_s 259200/' "$F" > "$F.t" && mv "$F.t" "$F"
  r=$(tick); [ "$r" = "shrink 4984 1" ] || fail "a shrink keeps 1.5x the peak used, as a multiple of 4 (got $r)"
  teardown
}
case_gap_caps_at_300() {
  setup; CUR_MB=4096; S_MEMTOTAL_KB=3850000; S_MEMAVAIL_KB=2750000; decide >/dev/null; tick >/dev/null
  b=$(key lowmem_s); NOW=$(( NOW + 86400 )); decide >/dev/null
  [ "$(key lowmem_s)" = $(( b + 300 )) ] || fail "a day asleep counts 300 s, not a day (was $b, now $(key lowmem_s))"
  teardown
}
case_high_sample_resets_window() {
  setup; CUR_MB=4096; S_MEMTOTAL_KB=3850000; S_MEMAVAIL_KB=2750000; decide >/dev/null; tick >/dev/null; tick >/dev/null
  [ "$(key lowmem_s)" -gt 0 ] || fail "quiet ticks accumulate"
  S_MEMAVAIL_KB=1000000; tick >/dev/null
  [ "$(key lowmem_s)" = 0 ] || fail "a busy sample starts the 3 days over (got $(key lowmem_s))"
  teardown
}
case_empty_sample_no_change() {
  setup; decide >/dev/null; cp "$F" "$WORK/before"; S_MEMTOTAL_KB=
  r=$(tick); [ "$r" = none ] || fail "an empty sample decides nothing (got $r)"
  cmp -s "$F" "$WORK/before" || fail "an empty sample leaves the state as it was"
  teardown
}
case_floor() {
  setup; decide >/dev/null; sed -e 's/^lowmem_s .*/lowmem_s 300000/' "$F" > "$F.t" && mv "$F.t" "$F"; S_MEMAVAIL_KB=900000
  r=$(tick); [ "$r" = none ] || fail "1 GB / 1 CPU never shrinks (got $r)"
  teardown
}
case_counter_reset_is_not_pressure() {
  setup; S_OOM=5; S_PSWPIN=90000; decide >/dev/null; S_OOM=0; S_PSWPIN=10   # the VM rebooted
  r=$(tick); [ "$r" = none ] || fail "counters that went down (a reboot) aren't pressure (got $r)"
  teardown
}

case_first_sample_records_only
case_oom_grows_now
case_double_clamps_to_live_cap
case_past_cap_is_restart
case_no_cap_grows_live
case_psi_memory_sustained
case_swapin_fallback
case_cpu_sustained
case_psi_cpu_sustained
case_streak_breaks
case_cooldown
case_size_change_starts_cooldown
case_at_ceiling
case_ceiling_clamps
case_shrink_after_3_days
case_shrink_keeps_headroom
case_gap_caps_at_300
case_high_sample_resets_window
case_empty_sample_no_change
case_floor
case_counter_reset_is_not_pressure
echo "autosize_policy_test: OK"
