#!/bin/sh
# platform: host-agnostic
# Consistency: the menu-bar app is an LSUIElement, and the pkg installs + launches it.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "docker_menubar_test: FAIL: $*" >&2; exit 1; }

grep -q 'LSUIElement' "$ROOT/menubar/Info.plist.in" || fail "app must be LSUIElement (agent)"
grep -q 'dev.mavergreen.DockerMenu' "$ROOT/menubar/CMakeLists.txt" || fail "bundle id missing"

# App icon derives from the project's shipping-container art (NOT a whale — see
# updater/ICON-CREDIT.txt), single-sourced from updater/ where the .icns is generated.
[ -f "$ROOT/updater/container-tools-updater.icns" ] || fail "container art .icns missing"
grep -q 'CFBundleIconFile' "$ROOT/menubar/Info.plist.in" || fail "Info.plist must declare CFBundleIconFile"
grep -q 'MACOSX_BUNDLE_ICON_FILE' "$ROOT/menubar/CMakeLists.txt" || fail "CMake must set MACOSX_BUNDLE_ICON_FILE"
grep -q 'container-tools-updater.icns' "$ROOT/menubar/CMakeLists.txt" || fail "menubar must bundle the container art .icns"

# Menu-bar glyph derives from the container art, NOT a whale (updater/ICON-CREDIT.txt),
# is a template image (inverts on light/dark menu bars), and encodes four VM states.
AD="$ROOT/menubar/AppDelegate.m"
if grep -qi 'whale' "$AD"; then fail "menu-bar glyph must not be a whale (see updater/ICON-CREDIT.txt)"; fi
if grep -qi 'docker mark' "$AD"; then fail "menu-bar glyph must not imitate the Docker mark"; fi
grep -qi 'container' "$AD" || fail "menu-bar glyph must draw a container"
grep -q 'template = YES' "$AD" || fail "menu-bar glyph must be a template image"
grep -q '"no-fusion"' "$AD" || fail "glyph must distinguish needs-attention states (no-fusion/absent/error)"
# VMware pauses the VM when the Mac's disk fills (ctl's host-disk-full): the menu must say so and
# flag attention, not offer Start Docker for a VM that is paused, not stopped.
[ "$(grep -c '"host-disk-full"' "$AD")" -ge 3 ] \
  || fail "menu must title, flag and special-case the host-disk-full state"

# On-demand "Check for Updates" hands off to the bundled Sparkle updater with --user
# (interactive check) — the same executable the daily LaunchAgent runs with --background.
grep -q 'Check for Updates' "$AD" || fail "menu must offer 'Check for Updates'"
# Must launch the updater via LaunchServices (open), NOT fork+exec on the executable: Sparkle's
# package-install needs a LaunchServices-launched host, or AuthorizationExecuteWithPrivileges fails
# (-60008). See the updater's Info.plist.in comment in shipyard.
grep -q '/usr/bin/open' "$AD" || fail "'Check for Updates' must launch the updater via open (LaunchServices), not fork+exec"
grep -q 'container-tools-updater.app' "$AD" || fail "'Check for Updates' must open the bundled updater .app"
if grep -q 'container-tools-updater.app/Contents/MacOS/container-tools-updater' "$AD"; then
  fail "'Check for Updates' must NOT fork+exec the updater executable directly (breaks Sparkle install)"
fi
grep -q '"--user"' "$AD" || fail "'Check for Updates' must run the updater with --user (interactive)"

# When the VM is on an older boot2docker.iso than the freshly-installed one, the menu (a reliable GUI
# session) surfaces a roll-onto-new-image action. This replaced the updater's post-install modal
# dialog, which silently failed to appear from its relaunched process (dogfooding 2026-07-31).
# Detection via the `image-status` verb; the action drives `image-upgrade`; both are docker-machine-ctl
# verbs, so the identical roll runs headless from the CLI (`docker-machine-ctl image-upgrade`).
grep -q 'Update VM Image' "$AD" || fail "menu must offer 'Update VM Image' when the VM image is stale"
grep -q 'overview.image' "$AD" || fail "menu must detect a stale VM image from the overview's image line"
grep -q 'image-upgrade'   "$AD" || fail "'Update VM Image' must drive the image-upgrade verb"

# A menu-bar extra (LSUIElement) has no app menu; binding Cmd-Q to Quit is not sensible.
if grep -q 'keyEquivalent:@"q"' "$AD"; then fail "Quit must carry no shortcut (no Cmd-Q on a menu-bar extra)"; fi

grep -q -- '--menubar-app' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh needs --menubar-app"
grep -q 'Applications/Mavericks Container Tools.app' "$ROOT/cmake/package_pkg.sh" \
  || fail "package_pkg.sh must install the app to /Applications"
grep -q -- '--postinstall-hook' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh must wire in the postinstall hook"
grep -q 'asuser' "$ROOT/cmake/postinstall-hook.sh" || fail "the postinstall hook must launch the app as the console user"

grep -q -- '--menubar-app' "$ROOT/.github/workflows/release.yml" || fail "release.yml must pass --menubar-app"
# The menu-bar app (and the updater) build through cmake/build_apps.sh with clang22, on the Linux
# build-apps job: shipyard-cmake on a Mac, the host's cmake on Linux (where shipyard's
# MavericksShipyard_DIR points find_package at the action checkout).
grep -qE '^[[:space:]]*run: sh cmake/build_apps\.sh ' "$ROOT/.github/workflows/release.yml" \
  || fail "release.yml must build the apps with cmake/build_apps.sh"
grep -q -- '-S "$ROOT/$app"' "$ROOT/cmake/build_apps.sh" || fail "build_apps.sh must configure each app's own project"
grep -q 'fetch-clang22.sh' "$ROOT/cmake/build_apps.sh" || fail "build_apps.sh must compile with clang22"

# Fusion-absent is actionable: a "Get VMware Fusion" item/handler runs the get-fusion helper, and a
# one-time alert (seeded in NSUserDefaults) prompts on first no-fusion. The old dead disabled item is gone.
grep -q 'doGetFusion' "$AD" || fail "menu must have a doGetFusion action for the no-fusion state"
grep -q '@selector(doGetFusion:)' "$AD" || fail "the Get-VMware-Fusion menu item must wire @selector(doGetFusion:)"
grep -q 'container-tools-get-fusion' "$AD" || fail "doGetFusion must run the get-fusion helper"
grep -q 'MDFusionPromptSeeded' "$AD" || fail "must guard the one-time Fusion alert via NSUserDefaults"
grep -q 'NSAlert' "$AD" || fail "must show an NSAlert when Fusion is absent"
grep -q '@"Get VMware Fusion' "$AD" || fail "menu/alert must offer 'Get VMware Fusion'"

# The VM's disk: a line in the menu from the overview's disk line (asked off the main thread, so
# opening the menu never waits on the VM), the attention badge when it is low, and
# a "Free Up Space…" action that confirms with `reclaimable` and then runs `free-space`. The disk
# filled silently once (2026-09-24); these are what make that visible and fixable from the menu.
MC="$ROOT/menubar/MDController.m"
grep -q 'overview.disk' "$AD" || fail "the disk line must come from the overview"
grep -q '@"Disk: ' "$AD" || fail "the menu must show a 'Disk: …' line"
grep -q '@"Disk almost full: ' "$AD" || fail "a low disk must read 'Disk almost full: …'"
grep -q 'diskLow' "$AD" || fail "a low disk must raise the icon's attention badge"
grep -q '@"Free Up Space…"' "$AD" || fail "the menu must offer 'Free Up Space…'"
grep -q 'runVerb:@"reclaimable"' "$AD" || fail "Free Up Space must confirm with what the reclaimable verb reports"
grep -q 'runAndRefresh:@"free-space"' "$AD" || fail "Free Up Space must drive the free-space verb"
grep -q 'not touched' "$AD" || fail "the Free Up Space confirmation must say containers and volumes are not touched"

echo "docker_menubar_test: OK"

# Live state (2026-11-23): the shell posts a Darwin notification on every change and the app asks
# overview-status, off the main thread, one at a time. No cache files, no rules of the app's own.
M="$ROOT/menubar"
grep -q 'dev.mavergreen.container-tools.changed' "$M/MDWatchers.m" || fail "the app must listen for the shell's change notification"
grep -q 'notify_register_dispatch' "$M/MDWatchers.m" || fail "listen with notify_register_dispatch"
grep -q 'overview-status' "$M/MDController.m" || fail "the app must ask overview-status"
grep -q 'stringWithContentsOfFile' "$M/MDController.m" && fail "the app must not read cache files"
grep -q 'vmxPid\]' "$AD" && fail "no synchronous vmx-pid lookup on the refresh path"
grep -q 'shownState' "$AD" && fail "the app adds no state rules of its own (overview-status folds readiness in)"
grep -q 'Checking Docker' "$AD" || fail "before the first overview the menu says Checking Docker…"
grep -q 'MDOverview.m' "$M/CMakeLists.txt" || fail "MDOverview.m must be built"
echo "docker_menubar_test: live-state OK"
