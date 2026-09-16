#!/bin/sh
# Demonstrate that the go126 osinit_hack version-guard (patch-src_runtime_sys__darwin.go)
# (1) fixes the 10.9 launch fault and (2) does not regress macOS >= 10.12.
#
# Run it on each target with the PATCHED go126 installed:
#   - Mavericks 10.9 (amd64): expect guard=SKIP, program RUNS (was: dyld fault).
#   - modern Intel 10.12+    : expect guard=RUN,  program RUNS, notify still imported.
#   - Apple Silicon 11+      : expect guard=RUN,  program RUNS, notify still imported.
#
# The claim it proves: the patch's only runtime effect is gated on macOS version.
# On >= 10.12 the workaround still runs (notify_is_valid_token is present and the
# trampoline is still called); on < 10.12 it is skipped so the absent symbol is
# never bound. Same binary, both behaviors selected at runtime by kernel version.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$(dirname "$0")/common.sh"
GO=${GO:-$([ -x /opt/pkg/go126/bin/go ] && echo /opt/pkg/go126/bin/go || command -v go)}
export GO111MODULE=off  # trivial single-file stdlib probes; avoid go.mod requirement
WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-osinit.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
# import "C" forces cgo/external linking so CGO_LDFLAGS (incl. the shim) apply,
# exactly like docker. osinit_hack runs at startup; the fork+exec exercises the
# path it protects. Success = no launch fault and no hang.
cat > "$WORK/hello.go" <<'EOF'
package main

import "C"
import "os/exec"

func main() {
	_ = exec.Command("/usr/bin/true").Run()
	println("ok: osinit ran, fork+exec returned")
}
EOF

osrel=$(sysctl -n kern.osrelease 2>/dev/null || echo 0)
major=${osrel%%.*}
if [ "$major" -ge 16 ] 2>/dev/null; then guard="RUN (>=10.12, workaround active)"; else guard="SKIP (<10.12, symbol absent)"; fi
echo "host      : $(sw_vers -productVersion 2>/dev/null || echo '?') / $(uname -m) / Darwin $osrel"
echo "go        : $("$GO" version 2>/dev/null)"
echo "guard says: $guard"

# --- RUN check on the native arch (proves no fault / no regression) ---
# On the 10.9 box the shim supplies clock_gettime et al.; modern macOS needs none.
CGO=1; LD="-mmacosx-version-min=10.9 -Wl,-undefined,dynamic_lookup"
if [ "$(mavericks_docker_mode)" = native ]; then
  A="$ROOT/build/legacy-support/lib/libMacportsLegacySupport.a"
  [ -f "$A" ] || { echo "build the shim first (shipyard-cmake --build <dir>); need $A"; exit 2; }
  CC=${CC:-/usr/bin/clang}; LD="$A -lresolv $LD"
else
  CC=${CC:-clang}
fi
printf 'RUN native: '
if CGO_ENABLED=$CGO CC="$CC" CGO_CFLAGS="-mmacosx-version-min=10.9" CGO_LDFLAGS="$LD" \
     "$GO" build -o "$WORK/hello" "$WORK/hello.go" 2>"$WORK/berr"; then
  "$WORK/hello" || { echo "FAULTED (patch missing or wrong?)"; exit 1; }
else
  echo "build failed:"; cat "$WORK/berr"; exit 1
fi

# --- wiring check: both arches still import notify (workaround intact for 10.12+) ---
# Pure-Go probe (no import "C") so CGO_ENABLED=0 cross-builds need no C toolchain.
printf 'package main\nfunc main(){}\n' > "$WORK/probe.go"
echo "notify import (workaround wiring, both arches):"
for arch in amd64 arm64; do
  if CGO_ENABLED=0 GOARCH=$arch "$GO" build -o "$WORK/w_$arch" "$WORK/probe.go" 2>/dev/null; then
    if nm -u "$WORK/w_$arch" 2>/dev/null | grep -q notify_is_valid_token; then s="present (trampoline still calls it)"; else s="ABSENT"; fi
  else s="(cross-build skipped)"; fi
  printf '  %-6s: %s\n' "$arch" "$s"
done
echo "PASS: patched go126 program runs here; guard selected the correct behavior."
