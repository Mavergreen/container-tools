#!/bin/sh
# platform: macOS-only -- drives shipyard's pkgbuild/productbuild/PlistBuddy helpers
# Assemble the (unsigned) container-tools product .pkg: the docker CLI + Compose + Machine binaries,
# the boot2docker.iso, and the Sparkle updater (app + shim + daily LaunchAgent), with a hard 10.9.5
# install floor. Signing + appcast happen separately (shared sign_and_appcast.sh) in the release
# workflow; this script only builds the .pkg.
#
# Product-specific payload layout lives HERE; the generic mechanics (updater staging, the OS-floor
# product archive) come from mavericks-shipyard via $SHIPYARD_SCRIPTS. Prints the .pkg path on stdout.
#
# Usage:
#   package_pkg.sh --out PKG --version V --docker BIN --compose BIN --machine BIN --iso ISO \
#     --updater-app APP.app --bootstrap BIN --common FILE --ctl BIN --migrate BIN --menubar-app APP.app \
#     --launch-agent PLIST [--msc-scripts DIR] [--resources DIR --welcome FILE]
set -eu
export COPYFILE_DISABLE=1

OUT=""; VER=""; DOCKER=""; COMPOSE=""; MACHINE=""; LAZY=""; ISO=""; UPD_APP=""; DOCKED=""; SYNC=""
BOOT=""; COMMON=""; CTL=""; MIGRATE=""; GETFUSION=""; MENUBAR=""; LAUNCHAGENT=""
SHIPYARD=""; RES=""; WELCOME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --version) VER="$2"; shift 2;;
    --docker) DOCKER="$2"; shift 2;;
    --compose) COMPOSE="$2"; shift 2;;
    --machine) MACHINE="$2"; shift 2;;
    --lazydocker) LAZY="$2"; shift 2;;
    --iso) ISO="$2"; shift 2;;
    --updater-app) UPD_APP="$2"; shift 2;;
    --docked) DOCKED="$2"; shift 2;;
    --sync-helper) SYNC="$2"; shift 2;;
    --bootstrap) BOOT="$2"; shift 2;;
    --common) COMMON="$2"; shift 2;;
    --ctl) CTL="$2"; shift 2;;
    --migrate) MIGRATE="$2"; shift 2;;
    --get-fusion) GETFUSION="$2"; shift 2;;
    --menubar-app) MENUBAR="$2"; shift 2;;
    --launch-agent) LAUNCHAGENT="$2"; shift 2;;
    --msc-scripts) SHIPYARD="$2"; shift 2;;
    --resources) RES="$2"; shift 2;;
    --welcome) WELCOME="$2"; shift 2;;
    *) echo "package_pkg: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$OUT" ] && [ -n "$VER" ] && [ -n "$DOCKER" ] && [ -n "$COMPOSE" ] && [ -n "$MACHINE" ] \
  && [ -n "$LAZY" ] && [ -n "$ISO" ] && [ -n "$UPD_APP" ] && [ -n "$DOCKED" ] && [ -n "$SYNC" ] \
  && [ -n "$BOOT" ] && [ -n "$COMMON" ] && [ -n "$CTL" ] && [ -n "$MIGRATE" ] && [ -n "$GETFUSION" ] && [ -n "$MENUBAR" ] && [ -n "$LAUNCHAGENT" ] \
  || { echo "package_pkg: need --out --version --docker --compose --machine --lazydocker --iso --updater-app --docked --sync-helper --bootstrap --common --ctl --migrate --get-fusion --menubar-app --launch-agent" >&2; exit 2; }
if [ -z "$SHIPYARD" ]; then
  # --msc-scripts wins when given; otherwise msc.sh takes $SHIPYARD_SCRIPTS (install@v1 exports it in
  # CI) or asks shipyard-cmake where find_package(MavericksShipyard) lands, and exits if neither works.
  . "$(dirname "$0")/../msc.sh"
fi
for f in "$DOCKER" "$COMPOSE" "$MACHINE" "$LAZY" "$ISO" "$DOCKED" "$SYNC" "$BOOT" "$COMMON" "$CTL" "$MIGRATE" "$GETFUSION" "$LAUNCHAGENT"; do [ -f "$f" ] || { echo "package_pkg: missing input: $f" >&2; exit 1; }; done
[ -d "$UPD_APP" ] || { echo "package_pkg: no updater .app: $UPD_APP" >&2; exit 1; }
[ -d "$MENUBAR" ] || { echo "package_pkg: no menubar .app: $MENUBAR" >&2; exit 1; }
for h in stage_product.sh set_install_floor.sh build_component_pkg.sh assert_pkg_installs_in_place.sh \
         postinstall-stop-gui.sh assert_gui_relaunch_safe.sh; do
  [ -f "$SHIPYARD/$h" ] || { echo "package_pkg: shared helper missing: $SHIPYARD/$h" >&2; exit 1; }
done

IDENT="dev.mavergreen.container-tools"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-pkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
stage="$WORK/stage"; scripts="$WORK/scripts"; comp="$WORK/component.pkg"

# --- product payload (docker CLI + plugins + iso) ---
T="$stage/usr/local/mavergreen/container-tools"
mkdir -p "$T/bin" "$T/libexec" "$T/lib/docker/cli-plugins" "$T/share"
install -m 0755 "$DOCKER"  "$T/bin/docker"
install -m 0755 "$MACHINE" "$T/bin/docker-machine"
install -m 0755 "$LAZY"    "$T/bin/lazydocker"
install -m 0755 "$DOCKED"  "$T/bin/docked"
install -m 0755 "$SYNC"    "$T/bin/container-tools-sync-image"
install -m 0755 "$BOOT"    "$T/bin/docker-machine-bootstrap"
install -m 0755 "$CTL"     "$T/bin/docker-machine-ctl"
install -m 0755 "$MIGRATE" "$T/bin/docker-machine-migrate"
install -m 0755 "$GETFUSION" "$T/bin/container-tools-get-fusion"
install -m 0644 "$COMMON"  "$T/libexec/docker-machine-common.sh"
install -m 0755 "$COMPOSE" "$T/lib/docker/cli-plugins/docker-compose"
ln -s ../lib/docker/cli-plugins/docker-compose "$T/bin/docker-compose"
install -m 0644 "$ISO"     "$T/share/boot2docker.iso"
mkdir -p "$stage/Applications"
cp -R "$MENUBAR" "$stage/Applications/Mavericks Container Tools.app"

# VM auto-start: a per-user LaunchAgent (ships ENABLED) driving the bootstrap helper. Auto-starts at
# login (the postinstall also `load`s it now); a user turns it off via the menu's "Start Docker at
# Login" toggle (login-off = unload -w, which survives upgrades). root:wheel 0644 so launchd accepts it.
mkdir -p "$stage/Library/LaunchAgents"
install -m 0644 "$LAUNCHAGENT" "$stage/Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist"

# --- updater app + LaunchAgent + postinstall (shared, hoisted) ---
mkdir -p "$scripts"
install -m 0644 "$SHIPYARD/postinstall-stop-gui.sh" "$scripts/stop-gui.sh"
find "$stage" -name '._*' -delete 2>/dev/null || true
sh "$SHIPYARD/stage_product.sh" --stage "$stage" --product container-tools \
  --name "Container Tools for Mavericks" --version "$VER" --updater-app "$UPD_APP" \
  --postinstall-hook "$(dirname "$0")/postinstall-hook.sh" --scripts-out "$scripts" >&2

# Gate the assembled postinstall -- a GUI-app relaunch must be preceded by a stop -- and confirm the
# staged helper parses + defines the function.
sh "$SHIPYARD/assert_gui_relaunch_safe.sh" "$scripts/postinstall" >&2
sh -n "$scripts/postinstall" || { echo "package_pkg: assembled postinstall has a syntax error" >&2; exit 1; }
sh -c '. "$1"; command -v mav_stop_gui_instance >/dev/null' _ "$scripts/stop-gui.sh" \
  || { echo "package_pkg: staged stop-gui.sh does not define mav_stop_gui_instance" >&2; exit 1; }

# --- flat component pkg over the whole payload, with the agent-loading postinstall ---
# Component pkg via the shared helper: it forces install-in-place -- BundleIsRelocatable=false, so the
# payload lands at its DECLARED path instead of being relocated onto a same-identifier bundle already
# on disk, and BundleIsVersionChecked=false, so an update never skips a component whose
# on-disk version looks newer. See mavericks-shipyard/scripts/build_component_pkg.sh.
sh "$SHIPYARD/build_component_pkg.sh" --root "$stage" --identifier "$IDENT" --version "$VER" \
  --install-location / --scripts "$scripts" --out "$comp" >&2

# --- product archive with the 10.9.5 OS floor (shared helper) ---
lic=""; [ -n "$WELCOME" ] && lic="--welcome $WELCOME"
resflag=""; [ -n "$RES" ] && resflag="--resources $RES"
sh "$SHIPYARD/set_install_floor.sh" \
  --identifier "$IDENT" \
  --title "Container Tools for Mavericks $VER" \
  --component "$comp" --out "$OUT" \
  $resflag $lic --require-scripts --host-arch x86_64 >&2

# Gate the shipped product archive: every bundle must install in place (no relocation, no version-skip).
# Catches a regression here or a future pkgbuild default before it reaches a user's machine.
sh "$SHIPYARD/assert_pkg_installs_in_place.sh" "$OUT" >&2

echo "$OUT"
