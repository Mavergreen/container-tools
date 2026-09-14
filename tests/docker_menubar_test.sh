#!/bin/sh
# Consistency: the menu-bar app is an LSUIElement, and the pkg installs + launches it.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "docker_menubar_test: FAIL: $*" >&2; exit 1; }

grep -q 'LSUIElement' "$ROOT/menubar/Info.plist.in" || fail "app must be LSUIElement (agent)"
grep -q 'dev.modernmavericks.DockerMenu' "$ROOT/menubar/CMakeLists.txt" || fail "bundle id missing"

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

# On-demand "Check for Updates" hands off to the bundled Sparkle updater with --user
# (interactive check) — the same executable the daily LaunchAgent runs with --background.
grep -q 'Check for Updates' "$AD" || fail "menu must offer 'Check for Updates'"
# Must launch the updater via LaunchServices (open), NOT fork+exec on the executable: Sparkle's
# package-install needs a LaunchServices-launched host, or AuthorizationExecuteWithPrivileges fails
# (-60008). See the updater's Info.plist.in comment in shipyard.
grep -q '/usr/bin/open' "$AD" || fail "'Check for Updates' must launch the updater via open (LaunchServices), not fork+exec"
grep -q 'ContainerToolsUpdater.app' "$AD" || fail "'Check for Updates' must open the bundled updater .app"
if grep -q 'ContainerToolsUpdater.app/Contents/MacOS/ContainerToolsUpdater' "$AD"; then
  fail "'Check for Updates' must NOT fork+exec the updater executable directly (breaks Sparkle install)"
fi
grep -q '"--user"' "$AD" || fail "'Check for Updates' must run the updater with --user (interactive)"

# When the VM is on an older boot2docker.iso than the freshly-installed one, the menu (a reliable GUI
# session) surfaces a roll-onto-new-image action. This replaced the updater's post-install modal
# dialog, which silently failed to appear from its relaunched process (dogfooding 2026-07-31).
# Detection via the `image-status` verb; the action drives `image-upgrade`; both are docker-machine-ctl
# verbs, so the identical roll runs headless from the CLI (`docker-machine-ctl image-upgrade`).
grep -q 'Update VM Image' "$AD" || fail "menu must offer 'Update VM Image' when the VM image is stale"
grep -q 'image-status'    "$AD" || fail "menu must detect a stale VM image via the image-status verb"
grep -q 'image-upgrade'   "$AD" || fail "'Update VM Image' must drive the image-upgrade verb"

# A menu-bar extra (LSUIElement) has no app menu; binding Cmd-Q to Quit is not sensible.
if grep -q 'keyEquivalent:@"q"' "$AD"; then fail "Quit must carry no shortcut (no Cmd-Q on a menu-bar extra)"; fi

grep -q -- '--menubar-app' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh needs --menubar-app"
grep -q 'Applications/Mavericks Container Tools.app' "$ROOT/cmake/package_pkg.sh" \
  || fail "package_pkg.sh must install the app to /Applications"
grep -q 'asuser' "$ROOT/cmake/package_pkg.sh" || fail "postinstall must launch the app as the console user"

grep -q -- '--menubar-app' "$ROOT/.github/workflows/release.yml" || fail "release.yml must pass --menubar-app"
# Anchored at command position: 'cmake -S menubar' is a substring of 'shipyard-cmake -S menubar', so
# the unanchored form cannot fail either way. Asserting the line is the only version with teeth.
grep -qE '^[[:space:]]*shipyard-cmake -S menubar([[:space:]]|$)' "$ROOT/.github/workflows/release.yml" \
  || fail "release.yml must build the menubar app with shipyard-cmake"
if grep -qE '^[[:space:]]*cmake -S menubar([[:space:]]|$)' "$ROOT/.github/workflows/release.yml"; then
  fail "release.yml configures menubar with a plain cmake (only shipyard-cmake configures against shipyard)"
fi

# Fusion-absent is actionable: a "Get VMware Fusion" item/handler runs the get-fusion helper, and a
# one-time alert (seeded in NSUserDefaults) prompts on first no-fusion. The old dead disabled item is gone.
grep -q 'doGetFusion' "$AD" || fail "menu must have a doGetFusion action for the no-fusion state"
grep -q '@selector(doGetFusion:)' "$AD" || fail "the Get-VMware-Fusion menu item must wire @selector(doGetFusion:)"
grep -q 'container-tools-get-fusion' "$AD" || fail "doGetFusion must run the get-fusion helper"
grep -q 'MDFusionPromptSeeded' "$AD" || fail "must guard the one-time Fusion alert via NSUserDefaults"
grep -q 'NSAlert' "$AD" || fail "must show an NSAlert when Fusion is absent"
grep -q '@"Get VMware Fusion' "$AD" || fail "menu/alert must offer 'Get VMware Fusion'"

echo "docker_menubar_test: OK"
