#!/bin/sh
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
for h in stage_updater.sh set_install_floor.sh build_component_pkg.sh assert_pkg_installs_in_place.sh \
         postinstall-stop-gui.sh assert_gui_relaunch_safe.sh; do
  [ -f "$SHIPYARD/$h" ] || { echo "package_pkg: shared helper missing: $SHIPYARD/$h" >&2; exit 1; }
done

IDENT="dev.modernmavericks.container-tools"
AGENT_LABEL="dev.modernmavericks.container-tools-updatecheck"
UPD_APPDIR="/Library/Application Support/ModernMavericks"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-pkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
stage="$WORK/stage"; scripts="$WORK/scripts"; comp="$WORK/component.pkg"

# --- product payload (docker CLI + plugins + iso) ---
mkdir -p "$stage/usr/local/bin" "$stage/usr/local/lib/docker/cli-plugins" "$stage/usr/local/share/modernmavericks/container-tools"
install -m 0755 "$DOCKER"  "$stage/usr/local/bin/docker"
install -m 0755 "$MACHINE" "$stage/usr/local/bin/docker-machine"
install -m 0755 "$LAZY"    "$stage/usr/local/bin/lazydocker"
install -m 0755 "$DOCKED"  "$stage/usr/local/bin/docked"
install -m 0755 "$SYNC"    "$stage/usr/local/bin/container-tools-sync-image"
install -m 0755 "$BOOT"    "$stage/usr/local/bin/docker-machine-bootstrap"
install -m 0755 "$CTL"    "$stage/usr/local/bin/docker-machine-ctl"
install -m 0755 "$MIGRATE" "$stage/usr/local/bin/docker-machine-migrate"
install -m 0755 "$GETFUSION" "$stage/usr/local/bin/container-tools-get-fusion"
mkdir -p "$stage/usr/local/libexec/modernmavericks/docker"
install -m 0644 "$COMMON" "$stage/usr/local/libexec/modernmavericks/docker/docker-machine-common.sh"
# Compose v2 as a CLI plugin (enables `docker compose`), plus a standalone `docker-compose` symlink.
install -m 0755 "$COMPOSE" "$stage/usr/local/lib/docker/cli-plugins/docker-compose"
ln -s ../lib/docker/cli-plugins/docker-compose "$stage/usr/local/bin/docker-compose"
install -m 0644 "$ISO"    "$stage/usr/local/share/modernmavericks/container-tools/boot2docker.iso"
mkdir -p "$stage/Applications"
cp -R "$MENUBAR" "$stage/Applications/Mavericks Container Tools.app"

# VM auto-start: a per-user LaunchAgent (ships ENABLED) driving the bootstrap helper. Auto-starts at
# login (the postinstall also `load`s it now); a user turns it off via the menu's "Start Docker at
# Login" toggle (login-off = unload -w, which survives upgrades). root:wheel 0644 so launchd accepts it.
mkdir -p "$stage/Library/LaunchAgents"
install -m 0644 "$LAUNCHAGENT" "$stage/Library/LaunchAgents/dev.modernmavericks.container-tools-machine.plist"

# --- updater app + LaunchAgent + postinstall (shared, hoisted) ---
sh "$SHIPYARD/stage_updater.sh" --stage "$stage" --app "$UPD_APP" --app-dir "$UPD_APPDIR" \
  --agent-label "$AGENT_LABEL" --scripts-out "$scripts"

# stage_updater.sh's generated postinstall ends with `exit 0`; drop a trailing standalone
# one so the launch below runs, then re-add exit 0 at the very end. Robust if it changes.
[ -f "$scripts/postinstall" ] || printf '#!/bin/sh\n' > "$scripts/postinstall"
sed -i '' -e '${/^[[:space:]]*exit 0[[:space:]]*$/d;}' "$scripts/postinstall"
cat >> "$scripts/postinstall" <<'POST'
# Converge on the renamed bundle. The .pkg lays down "/Applications/Mavericks Container Tools.app",
# but installing over a pre-rename box leaves the old "/Applications/Container Tools for Mavericks.app"
# behind -- still the running menu-bar process and still the registered Login Item (MDLoginItem keys
# on the bundle URL) -- so the user keeps seeing the old name. Stop the old process and remove its
# bundle (identity-checked, so an unrelated app is never touched) before (re)launching the new one,
# which re-registers the Login Item at the new path.
_uid=$(stat -f %u /dev/console 2>/dev/null)
if [ -n "$_uid" ] && [ "${_uid:-0}" -gt 0 ]; then
  # Stop any old menu-bar instance before the launch below, or the two coexist and the user sees two
  # icons. Shared helper (postinstall-stop-gui.sh, staged beside this script as stop-gui.sh); it matches
  # the Contents/MacOS exec name -- unchanged across the rename -- so it also stops an app still running
  # from the old bundle.
  . "$(dirname "$0")/stop-gui.sh"
  mav_stop_gui_instance 'Contents/MacOS/DockerMenu' "$_uid"
  # One-time cleanup of the pre-rename bundle, but ONLY if it is ours (identity-checked, so we never
  # delete an unrelated /Applications/Container Tools for Mavericks.app) AND only once the new bundle
  # is actually in place. The [ -d "$NEW_APP" ] guard is the safety belt: if bundle relocation ever
  # writes the payload back onto OLD_APP (leaving NEW_APP absent), removing OLD_APP would delete the
  # app we just installed -- the exact failure that emptied /Applications on the .12 install.
  NEW_APP="/Applications/Mavericks Container Tools.app"
  OLD_APP="/Applications/Container Tools for Mavericks.app"
  if [ -d "$NEW_APP" ] && [ "$OLD_APP" != "$NEW_APP" ] && [ -d "$OLD_APP" ] && \
     [ "$(defaults read "$OLD_APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "dev.modernmavericks.DockerMenu" ]; then
    rm -rf "$OLD_APP"
  fi
  # Launch the (new) menu-bar app as the console user so it registers its Login Item and appears
  # immediately (installer runs as root).
  launchctl asuser "$_uid" open -a "/Applications/Mavericks Container Tools.app" >/dev/null 2>&1 || true
  # Start the Docker VM now, as the console user (VM creation needs the user's Fusion/GUI session,
  # not root). Plain `load` (no -w): the plist ships enabled so a fresh install auto-starts, while a
  # user who chose "Start Docker at Login → off" (unload -w) keeps that opt-out through upgrades.
  launchctl asuser "$_uid" load "/Library/LaunchAgents/dev.modernmavericks.container-tools-machine.plist" >/dev/null 2>&1 || true
fi
exit 0
POST
chmod +x "$scripts/postinstall"

# Stage the shared stop-the-old-menu-bar-instance helper the postinstall sources (present at install
# time on the target; a build-host script is not). Then gate the assembled postinstall -- a GUI-app
# relaunch must be preceded by a stop -- and confirm the staged helper parses + defines the function.
install -m 0644 "$SHIPYARD/postinstall-stop-gui.sh" "$scripts/stop-gui.sh"
sh "$SHIPYARD/assert_gui_relaunch_safe.sh" "$scripts/postinstall" >&2
sh -n "$scripts/postinstall" || { echo "package_pkg: assembled postinstall has a syntax error" >&2; exit 1; }
sh -c '. "$1"; command -v mav_stop_gui_instance >/dev/null' _ "$scripts/stop-gui.sh" \
  || { echo "package_pkg: staged stop-gui.sh does not define mav_stop_gui_instance" >&2; exit 1; }

# --- flat component pkg over the whole payload, with the agent-loading postinstall ---
# Strip AppleDouble sidecars copied in from the (NFS) source tree. NOTE: macOS 26 stamps an
# UNREMOVABLE com.apple.provenance xattr on every Mach-O, and pkgbuild encodes each as a ._ payload
# entry -- unavoidable, and identical to golang/swift's shipped pkgs. Those merge back into inert
# xattrs when Installer extracts onto the 10.9 box's HFS+, so no ._ FILES land on the target.
find "$stage" -name '._*' -delete 2>/dev/null || true
# Component pkg via the shared helper: it forces install-in-place -- BundleIsRelocatable=false, so the
# payload lands at its DECLARED path instead of being relocated onto a same-identifier bundle already
# on disk (the bug that kept reinstalling the menu-bar app under its pre-rename name and left the
# rename un-applied), and BundleIsVersionChecked=false, so an update never skips a component whose
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
