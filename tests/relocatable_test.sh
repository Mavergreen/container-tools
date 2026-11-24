#!/bin/sh
# platform: host-agnostic
# The product tree runs from wherever it is: the .pkg's install location, or wherever the standalone
# archive is unpacked. So no script in the tree names /usr/local/mavergreen (not even in a comment:
# shipyard's check-standalone-archive.sh reads every line), and each finds libexec/ and share/ from
# its own location, through a symlink like the ones /usr/local/mavergreen/bin holds.
# spec: shipyard SKILL.md "Standalone archive" -- a script in the archive never names /usr/local/mavergreen.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "relocatable_test: FAIL: $*" >&2; exit 1; }

# Everything package_pkg.sh puts in the tree (the LaunchAgent plist is pkg-only, outside it).
TREE_FILES="docked docker-machine-bootstrap docker-machine-ctl docker-machine-migrate container-tools-sync-image container-tools-get-fusion docker-machine-common.sh"
for f in $TREE_FILES; do
  [ -f "$ROOT/payload/$f" ] || fail "no payload/$f"
  ! grep -n '/usr/local/mavergreen' "$ROOT/payload/$f" >&2 || fail "payload/$f names /usr/local/mavergreen (lines above)"
done

T=$(mktemp -d "${TMPDIR:-/tmp}/relocatable_test.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
ct="$T/somewhere else/container-tools-1"   # a space, as an unpacked path may have
mkdir -p "$ct/bin" "$ct/libexec" "$ct/share" "$T/links" "$T/home" "$T/stub"
for f in docker-machine-ctl docker-machine-bootstrap; do cp "$ROOT/payload/$f" "$ct/bin/$f"; done
cp "$ROOT/payload/docker-machine-common.sh" "$ROOT/payload/vm-provider-fusion.sh" "$ct/libexec/"
printf 'ISO\n' > "$ct/share/boot2docker.iso"
ln -s "../somewhere else/container-tools-1/bin/docker-machine-ctl" "$T/links/docker-machine-ctl"
mkdir -p "$T/home/.docker/machine/machines/container-tools"
cp "$ct/share/boot2docker.iso" "$T/home/.docker/machine/machines/container-tools/boot2docker.iso"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/notifyutil"; chmod +x "$T/stub/notifyutil"

# unset, not env -u: 10.9's /usr/bin/env has no -u.
out=$(cd / && unset MAVERICKS_DOCKER_COMMON MAVERICKS_DOCKER_ISO MAVERICKS_DOCKER_BINDIR MAVERICKS_DOCKER_MACHDIR && env \
  HOME="$T/home" MAVERICKS_DOCKER_FUSION_PRESENT=1 MAVERICKS_DOCKER_LOG="$T/log" MAVERICKS_DOCKER_STATE_DIR="$T/state" \
  PATH="$T/stub:/usr/bin:/bin" "$T/links/docker-machine-ctl" image-status 2>"$T/err") \
  || fail "ctl through a symlink to a relocated tree failed: $(cat "$T/err")"
[ "$out" = current ] || fail "ctl must find the relocated tree's share/boot2docker.iso (image-status: '$out'; $(cat "$T/err"))"
echo "relocatable_test: OK"
