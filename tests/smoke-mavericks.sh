#!/bin/sh
# platform: macOS-only -- exercises the installed product on a real 10.9 box
# Real-10.9 acceptance: the product as a user installs it, on Mac OS X 10.9. release.yml's on-mavericks
# job installs the release's pkg on a real 10.9.5 guest (Mavergreen/mavericks-vm) and runs this; publish
# waits for it, and a skip (77) fails there. Anywhere else it skips: not 10.9, or nothing installed.
#
# Not exercised here, because the guest cannot run them (INGREDIENTS.md "Acceptance on real 10.9"):
# the Docker VM itself (VMware Fusion does not run nested in the QEMU guest, so nothing that needs the
# daemon -- docked, docker run -- and no create/start/stop), and the menu bar app's and updater's GUI.
set -eu
sw="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
case "$sw" in 10.9*) : ;; *) echo "not 10.9 ($sw) -- skipping"; exit 77 ;; esac
T=/usr/local/mavergreen/container-tools
[ -f "$T/mavergreen.plist" ] || { echo "container-tools not installed -- skipping"; exit 77; }
# It checks the INSTALLED product, so it runs only when told which version was installed: on a
# developer's 10.9 box, whatever happens to be installed is not what the checkout describes.
[ -n "${CT_VERSION:-}" ] || { echo "CT_VERSION (the version just installed) not set -- skipping"; exit 77; }
got="$(/usr/libexec/PlistBuddy -c 'Print :version' "$T/mavergreen.plist" 2>/dev/null || :)"
[ "$got" = "$CT_VERSION" ] || { echo "FAIL: installed container-tools is '$got', not $CT_VERSION" >&2; exit 1; }
B=/usr/local/mavergreen/bin
OUT="${TMPDIR:-/tmp}/ct-smoke.$$"; trap 'rm -f "$OUT"' EXIT

fail() { echo "FAIL: $1" >&2; [ -s "$OUT" ] && { echo "--- output:" >&2; tail -n 20 "$OUT" >&2; }; exit 1; }
runs() { # description, expected substring, command...
  _what=$1; _want=$2; shift 2
  "$@" > "$OUT" 2>&1 || fail "$_what exited non-zero"
  grep -q "$_want" "$OUT" || fail "$_what does not say '$_want'"
  echo "ok: $_what"
}

# The pkg installed and its postinstall ran: the helper knows the product and its links are sound.
/usr/local/bin/mavergreen list > "$OUT" 2>&1 || fail "mavergreen list exited non-zero"
grep -q '^container-tools ' "$OUT" || fail "mavergreen list does not show container-tools"
/usr/local/bin/mavergreen check > "$OUT" 2>&1 || fail "mavergreen check found broken links or drift"
echo "ok: installed and linked"

# Every shipped Go executable runs on 10.9 -- the failure class (a dyld fault at launch, like Go's
# osinit_hack notify crash) that inspecting the binaries cannot rule out. `docker compose` also proves
# the CLI finds its compose plugin in the container-tools tree (the cli-plugins patch).
runs "docker --version"             'Docker version'         "$B/docker" --version
runs "docker compose version"       'Docker Compose version' "$B/docker" compose version
runs "docker-compose --version"     'Docker Compose version' "$B/docker-compose" --version
runs "docker-machine --version"     'docker-machine version' "$B/docker-machine" --version
runs "lazydocker --version"         'Version'                "$B/lazydocker" --version

# The shell helpers run under 10.9's own /bin/sh and tools, against a machine with no VM.
STATE="$HOME/Library/Application Support/Mavergreen/container-tools/state"
"$B/docker-machine-ctl" status > "$OUT" 2>&1 || fail "docker-machine-ctl status exited non-zero"
case "$(cat "$OUT")" in
  running|stopped|absent|creating|no-fusion|error|working:*) echo "ok: docker-machine-ctl status ($(cat "$OUT"))" ;;
  *) fail "docker-machine-ctl status printed no status word" ;;
esac
"$B/docker-machine-ctl" disk-status > "$OUT" 2>&1 || fail "docker-machine-ctl disk-status exited non-zero"
grep -Eq '^(unknown|[0-9]+ [0-9]+ [0-9]+ (ok|low))$' "$OUT" || fail "docker-machine-ctl disk-status printed no disk line"
echo "ok: docker-machine-ctl disk-status ($(cat "$OUT"))"
"$B/container-tools-sync-image" > "$OUT" 2>&1 || fail "container-tools-sync-image exited non-zero"
echo "ok: container-tools-sync-image"
if [ ! -d "/Applications/VMware Fusion.app" ] && ! command -v vmrun >/dev/null 2>&1; then
  # The guest has no Fusion, so the login agent's bootstrap must stand down and say so, not fail.
  MAVERICKS_DOCKER_NONINTERACTIVE=1 "$B/docker-machine-bootstrap" > "$OUT" 2>&1 || fail "docker-machine-bootstrap exited non-zero"
  [ "$(cat "$STATE" 2>/dev/null)" = no-fusion ] || fail "without VMware Fusion, bootstrap must announce no-fusion (state: $(cat "$STATE" 2>/dev/null))"
  echo "ok: docker-machine-bootstrap without VMware Fusion -> no-fusion"
fi

# What the pkg puts outside the tree: the login agent, the menu bar app and the updater.
plutil -lint /Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist > "$OUT" 2>&1 \
  || fail "the machine LaunchAgent plist does not lint"
[ -x "/Applications/Mavericks Container Tools.app/Contents/MacOS/DockerMenu" ] || fail "the menu bar app is not installed"
[ -d "/Library/Application Support/Mavergreen/container-tools-updater.app" ] || fail "the updater is not installed"
echo "ok: LaunchAgent, menu bar app and updater in place"

echo "ok: real-10.9 smoke"
