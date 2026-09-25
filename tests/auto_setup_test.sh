#!/bin/sh
# platform: host-agnostic
# Static assertions for the auto-setup wiring: agent ships enabled+silent, postinstall loads it
# per-user (no -w), and the get-fusion helper is installed.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "auto_setup_test: FAIL: $*" >&2; exit 1; }

PLIST="$ROOT/payload/dev.mavergreen.container-tools-machine.plist"

# Agent must NOT ship Disabled=true (it must auto-enable), and must run bootstrap silently.
if grep -A1 '<key>Disabled</key>' "$PLIST" | grep -q '<true/>'; then
  fail "LaunchAgent still ships Disabled=true (must be enabled by default)"
fi
grep -q 'MAVERICKS_DOCKER_NONINTERACTIVE' "$PLIST" || fail "agent must set MAVERICKS_DOCKER_NONINTERACTIVE (silent create)"
grep -q '<key>RunAtLoad</key>' "$PLIST" || fail "agent must keep RunAtLoad"
grep -q '<key>StartInterval</key>' "$PLIST" || fail "agent must keep StartInterval"

PKG="$ROOT/cmake/package_pkg.sh"
HOOK="$ROOT/cmake/postinstall-hook.sh"
# The postinstall hook must load the machine agent for the console user, WITHOUT -w
# (so a user's explicit login-off opt-out survives upgrades).
grep -q 'launchctl asuser "\$_uid" load' "$HOOK" \
  || fail "the postinstall hook must 'launchctl asuser \$_uid load' the machine agent"
grep -q 'container-tools-machine.plist' "$PKG" \
  || fail "postinstall must reference the machine LaunchAgent plist"
if grep -q 'launchctl asuser "\$_uid" load -w' "$HOOK"; then
  fail "the postinstall hook must NOT use 'load -w' (that would stomp an explicit opt-out)"
fi

# package_pkg.sh must accept --get-fusion and install it into the product tree.
grep -q '\-\-get-fusion) GETFUSION=' "$PKG" || fail "package_pkg.sh must parse --get-fusion"
grep -q 'T/bin/container-tools-get-fusion' "$PKG" \
  || fail "package_pkg.sh must install container-tools-get-fusion into the product tree's bin/"
# release.yml must pass the helper through.
grep -q '\-\-get-fusion payload/container-tools-get-fusion' "$ROOT/.github/workflows/release.yml" \
  || fail "release.yml must pass --get-fusion payload/container-tools-get-fusion"

echo "auto_setup_test: OK"
