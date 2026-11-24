# platform: macOS-only -- VMware Fusion 8.5 for Mac (vmrun, libvix, vmware-vdiskmanager, .vmx/.vmem/.vmdk)
# vm-provider-fusion.sh -- everything Container Tools knows about the VM's provider, VMware Fusion.
# docker-machine-common.sh sources it, and the rest of the payload talks to the VM only through these
# vm_* functions, so another provider means another file with the same functions (2026-11-24).
# Needs from common: MACHDIR, MACHINE, CT_HOME (optional), log.
#
# The interface:
#   vm_provider_name            the provider's name, for messages
#   vm_provider_present         the provider is installed
#   vm_create_args              docker-machine create's driver arguments, shell-quoted (boots $ISO)
#   vm_pid                      the running VM's process id, or nothing
#   vm_suspended                the VM is suspended (it resumes from saved state)
#   vm_paused_for_host_disk     the provider paused the VM because the Mac's disk is full
#   vm_size                     "MB CPUS" as configured; a value it can't read is empty
#   vm_size_source              a word naming where vm_size reads from (resource-status's source=)
#   vm_set_size MB CPUS         configure a stopped, not suspended VM; fails otherwise
#   vm_boot_disk_kb MB          KB of the Mac's disk a power-on at MB uses
#   vm_prepare                  bring a stopped VM's configuration up to what Container Tools needs
#   vm_live_resize_ready        the VM's configuration allows growing it while it runs
#   vm_live_memory_max_mb       the most memory a live grow can reach for this boot, or nothing (no cap known)
#   vm_hot_add_memory MB        grow the running VM's memory to MB (prints the provider's reason on failure)
#   vm_hot_add_cpus N           grow the running VM's CPUs to N (likewise)
#   vm_disk_sectors             the VM disk's size in 512-byte sectors, or why it can't be grown and fail
#   vm_grow_disk GB             grow the stopped VM's disk to GB

_fusion_vmx() { echo "$MACHDIR/$MACHINE/$MACHINE.vmx"; }
_fusion_log() { echo "$MACHDIR/$MACHINE/vmware.log"; }
_fusion_vmx_value() { sed -n "s/^$1 *= *\"\\([0-9]*\\)\".*/\\1/p" "$(_fusion_vmx)" 2>/dev/null | head -1; }

vm_provider_name() { echo "VMware Fusion"; }
vm_provider_present() {
  [ "${MAVERICKS_DOCKER_FUSION_PRESENT:-}" = 0 ] && return 1
  [ "${MAVERICKS_DOCKER_FUSION_PRESENT:-}" = 1 ] && return 0
  [ -d "/Applications/VMware Fusion.app" ] || command -v vmrun >/dev/null 2>&1
}
vm_create_args() { printf "%s '%s'\n" '-d vmwarefusion --vmwarefusion-boot2docker-url' "$ISO"; }

vm_pid() { pgrep -f "machines/$MACHINE/.*\.vmx" 2>/dev/null | head -1 || true; }
vm_suspended() { grep -q '^checkpoint\.vmState *= *"[^"]' "$(_fusion_vmx)" 2>/dev/null; }

# VMware pauses the VM when the Mac's disk fills, and asks a noSpace (guest RAM's .vmem) or
# outofspace (the virtual disk) question in vmware.log once a second until it can carry on. Meanwhile
# docker-machine's status flaps and every docker-machine command waits, so this is the one thing
# worth telling the user. "Still asking" = the vmx is up and the log was written in the last 10s.
vm_paused_for_host_disk() {
  # "Still asking" is judged by the newest question's own timestamp, never the log's mtime: on
  # 2026-11-22 a question answered at 11:42 was still among the last 12 lines at 12:08, and an
  # unrelated line had just freshened the file, so the running VM read as paused. VMware stamps local
  # time; both sides are turned into seconds by plain awk arithmetic (no BSD/GNU date parsing).
  _vl=$(_fusion_log)
  [ -f "$_vl" ] && [ -n "$(vm_pid)" ] || return 1
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

vm_size() {
  _fs_m=$(_fusion_vmx_value memsize); _fs_c=$(_fusion_vmx_value numvcpus)
  echo "$_fs_m $_fs_c"
}
vm_size_source() { echo vmx; }
vm_set_size() { # MB CPUS -- only for a VM that is neither running nor suspended
  _sv_vmx=$(_fusion_vmx); _sv_tmp="$_sv_vmx.ct-tmp"
  [ -f "$_sv_vmx" ] && [ -z "$(vm_pid)" ] && ! vm_suspended || return 1
  { awk '!/^memsize *=/ && !/^numvcpus *=/' "$_sv_vmx"; printf 'memsize = "%s"\nnumvcpus = "%s"\n' "$1" "$2"; } > "$_sv_tmp" \
    && cat "$_sv_tmp" > "$_sv_vmx"   # cat keeps its mode
  rm -f "$_sv_tmp"
}
# Fusion backs guest RAM with a memsize-sized .vmem file in the VM's directory, allocated in full at
# every power-on; for a 16 GB VM, that file is what filled the Mac's disk on 2026-10-24. (Fusion 8.5
# for Mac reads mainMem.useNamedFile = "FALSE" and ignores it -- tried the same day.)
vm_boot_disk_kb() { echo $(( $1 * 1024 )); }

# Suspend stays allowed, and hard; hot-add is on. A soft suspend runs the guest's VMware Tools network
# script, which on boot2docker flushes every interface's address and can't restore it, so the VM
# resumes unreachable; that is why Wowfunhappy's docker-machine wrote suspend.disabled = "TRUE", and
# why every VM through 20261025.17 had it. A hard suspend skips the guest scripts and resumes intact
# (spike, 2026-11-24). Suspend must stay allowed, and mem/vcpu.hotadd on, because VMware hot-adds
# memory and CPUs (ctl resize, growing live) by a suspend-and-resume. components/docker-machine/
# patches/0002 and 0003 create VMs this way; this converts one created before them. Only while
# stopped and not suspended: Fusion reads the .vmx at power-on and may rewrite it while running, and a
# suspended VM resumes against the .vmx it was suspended with.
_FUSION_VMX_READY='powerType.suspend = "hard"
mem.hotadd = "TRUE"
vcpu.hotadd = "TRUE"'
vm_live_resize_ready() {
  _ah_vmx=$(_fusion_vmx)
  [ -f "$_ah_vmx" ] || return 1
  grep -q '^suspend\.disabled *= *"TRUE"' "$_ah_vmx" && return 1
  grep -q '^powerType\.suspend *= *"hard"' "$_ah_vmx" && grep -q '^mem\.hotadd *= *"TRUE"' "$_ah_vmx" \
    && grep -q '^vcpu\.hotadd *= *"TRUE"' "$_ah_vmx"
}
vm_prepare() {
  _pv_vmx=$(_fusion_vmx)
  [ -f "$_pv_vmx" ] && [ -z "$(vm_pid)" ] || return 0
  vm_suspended && return 0
  vm_live_resize_ready && return 0
  _pv_tmp="$_pv_vmx.ct-tmp"
  { awk '!/^suspend\.disabled *= *"TRUE"/ && !/^powerType\.suspend *=/ && !/^mem\.hotadd *=/ && !/^vcpu\.hotadd *=/' "$_pv_vmx"
    printf '%s\n' "$_FUSION_VMX_READY"; } > "$_pv_tmp" && cat "$_pv_tmp" > "$_pv_vmx"   # cat keeps its mode
  rm -f "$_pv_tmp"
  log "prepared $_pv_vmx for hard suspend and hot-add"
}

# Fusion grows a VM that booted with less than 3 GB only up to 3 GB live ("greater than allowed
# maximum of 3072MB"); one booted at 4 GB grew live to 16 GB (2026-11-24).
# vmware.log starts afresh at each power-on, and its first DICT memsize is the boot size (a hot-add
# rewrites the .vmx's, not this).
vm_live_memory_max_mb() {
  _lb=$(sed -n 's/.*DICT  *memsize = "\([0-9]*\)".*/\1/p' "$(_fusion_log)" 2>/dev/null | head -1)
  case "$_lb" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_lb" -lt 3072 ] && echo 3072
  return 0
}
# libexec/container-tools-hotplug: Fusion's own libvix hot-add calls (VixVM_HotPlugMemory/CPU).
FUSION_HOTPLUG=${MAVERICKS_DOCKER_HOTPLUG:-${CT_HOME:+$CT_HOME/libexec/container-tools-hotplug}}
_fusion_hotplug() { # --memory MB | --cpus N
  [ -n "$FUSION_HOTPLUG" ] && [ -x "$FUSION_HOTPLUG" ] || { echo "The hot-add helper is missing (${FUSION_HOTPLUG:-container-tools-hotplug})."; return 1; }
  "$FUSION_HOTPLUG" "$(_fusion_vmx)" "$@" 2>&1
}
vm_hot_add_memory() { _fusion_hotplug --memory "$1"; }
vm_hot_add_cpus() { _fusion_hotplug --cpus "$1"; }

# vmware-vdiskmanager grows a single sparse vmdk with no snapshots.
FUSION_VDISKMANAGER=${MAVERICKS_DOCKER_VDISKMANAGER:-/Applications/VMware Fusion.app/Contents/Library/vmware-vdiskmanager}
vm_disk_sectors() {
  _vmdk="$MACHDIR/$MACHINE/$MACHINE.vmdk"
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
  echo "$_sec"
}
vm_grow_disk() { "$FUSION_VDISKMANAGER" -x "${1}GB" "$MACHDIR/$MACHINE/$MACHINE.vmdk"; }
