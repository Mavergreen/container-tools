#!/bin/sh
# The VM's provider is a seam (2026-11-24): everything that knows the VM runs in VMware Fusion lives in
# payload/vm-provider-fusion.sh, behind the vm_* functions its header lists, so another provider is
# another file with the same functions. This holds the rest of the payload to it.
set -u
ROOT=${SEAM_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
P="$ROOT/payload/vm-provider-fusion.sh"
fail() { echo "vm_provider_seam_test: FAIL: $*" >&2; exit 1; }
[ -f "$P" ] || fail "no payload/vm-provider-fusion.sh"

# Every function the header promises is defined, and nothing else public is.
_promised=$(sed -n 's/^#   \(vm_[a-z_]*\).*/\1/p' "$P" | sort)
_defined=$(sed -n 's/^\(vm_[a-z_]*\)() *{.*/\1/p' "$P" | sort)
[ -n "$_promised" ] || fail "the header lists no vm_* interface"
[ "$_promised" = "$_defined" ] || fail "header and definitions differ: promised [$(echo $_promised)] defined [$(echo $_defined)]"

# The provider-neutral scripts reach Fusion only through it. Comments may name Fusion (they say why);
# code may not. Allowed: the menu's wire words (vmx-pid, no-fusion) and notify's 'fusion' key.
for f in docker-machine-common.sh docker-machine-bootstrap docker-machine-ctl autosize.sh; do
  _hits=$(grep -n -E '\.vmx|\.vmem|\.vmdk|vmware|vmrun|vdiskmanager|libvix|hotplug|VMware|Fusion|vmwarefusion|[^.]memsize|numvcpus|checkpoint\.|_fusion' "$ROOT/payload/$f" \
    | grep -v -E '^[0-9]+: *#' | grep -v -E 'vmx-pid|no-fusion|notify fusion' | grep -v -E '^[0-9]+:.*[^\\]# ' || true)
  [ -z "$_hits" ] || fail "$f reaches Fusion directly:
$_hits"
done
echo "vm_provider_seam_test: OK"
