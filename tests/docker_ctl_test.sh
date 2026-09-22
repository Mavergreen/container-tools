#!/bin/sh
# Unit tests for docker-machine-ctl verbs via PATH stubs.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CTL="$ROOT/payload/docker-machine-ctl"
[ -f "$CTL" ] || { echo "docker_ctl_test: ctl missing" >&2; exit 1; }
fail() { echo "docker_ctl_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-ctl.XXXXXX")
  BIN="$WORK/bin"; mkdir -p "$BIN"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state"
  export MAVERICKS_DOCKER_LOG="$WORK/log"
  export MAVERICKS_DOCKER_FUSION_PRESENT=1
  export MAVERICKS_DOCKER_COMMON="$ROOT/payload/docker-machine-common.sh"
  export DM_LOG="$WORK/dm.args"; : > "$DM_LOG"
  export LC_LOG="$WORK/lc.args"; : > "$LC_LOG"
  export DOCKER_LOG="$WORK/docker.args"; : > "$DOCKER_LOG"
  OLDPATH=$PATH; PATH="$BIN:$PATH"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }

stub_dm() { # $1 = status word
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
[ "\$1" = status ] && { echo "$1"; exit 0; }
exit 0
EOF
  chmod +x "$BIN/docker-machine"
}
stub_launchctl() { # $1 = exit code for "list" (0 = loaded/on, 1 = not loaded/off)
  cat > "$BIN/launchctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$LC_LOG"
case "\$1" in list) exit $1 ;; *) exit 0 ;; esac
EOF
  chmod +x "$BIN/launchctl"
}

case_status() {
  setup; stub_dm Running
  [ "$(sh "$CTL" status)" = running ] || fail "status running"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state")" = running ] || fail "status writes state"
  teardown
}
case_start_stop() {
  setup; stub_dm Running
  sh "$CTL" start >/dev/null || fail "start exit 0"
  grep -q '^start container-tools' "$DM_LOG" || fail "start calls docker-machine start container-tools"
  sh "$CTL" stop >/dev/null || fail "stop exit 0"
  grep -q '^stop container-tools' "$DM_LOG" || fail "stop calls docker-machine stop container-tools"
  teardown
}

# VM up on a NEW IP while the mavericks context still holds the OLD IP — the renumber that
# makes `docker ps` hang. A running-VM verb must self-heal by re-pointing the context.
# (docker-machine env reports the VM's real current IP, so detection never hangs on the stale one.)
stub_renumbered() {
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  env) echo 'export DOCKER_HOST="tcp://10.0.0.5:2376"'; echo 'export DOCKER_CERT_PATH="/tmp/certs"' ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker-machine"
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$*" in
  *"context inspect mavericks --format"*) echo "tcp://10.0.0.4:2376" ;;   # stale (old) host
  *"context inspect mavericks"*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker"
}
case_start_syncs_context() {
  setup; stub_renumbered
  sh "$CTL" start >/dev/null || fail "start exit 0"
  grep -q '^start container-tools' "$DM_LOG" || fail "start calls docker-machine start"
  grep -q '^env container-tools' "$DM_LOG" || fail "start must sync context after starting"
  grep -q 'context update mavericks' "$DOCKER_LOG" || fail "start must re-point mavericks at the current IP"
  grep -q 'context use mavericks' "$DOCKER_LOG" || fail "start must select the mavericks context"
  teardown
}
# No sync on the read path: status must stay fast (no docker-machine env) — there's no cheap
# renumber detector, so healing every poll would tax the happy path. Renumber is a restart
# event (start/restart heals) and the login-agent timer covers out-of-band restarts.
case_status_stays_fast() {
  setup; stub_renumbered
  [ "$(sh "$CTL" status)" = running ] || fail "status running"
  grep -q '^env container-tools' "$DM_LOG" && fail "status must NOT call docker-machine env (keep happy path fast)"
  grep -q 'context update' "$DOCKER_LOG" 2>/dev/null && fail "status must not re-point the context"
  teardown
}
case_login() {
  setup; stub_launchctl 0
  [ "$(sh "$CTL" login-status)" = on ] || fail "loaded -> on"
  stub_launchctl 1
  [ "$(sh "$CTL" login-status)" = off ] || fail "not loaded -> off"
  sh "$CTL" login-on >/dev/null
  grep -q 'load -w /Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist' "$LC_LOG" || fail "login-on loads the plist"
  sh "$CTL" login-off >/dev/null
  grep -q 'unload -w /Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist' "$LC_LOG" || fail "login-off unloads the plist"
  teardown
}
case_vmxpid() {
  setup
  cat > "$BIN/pgrep" <<'EOF'
#!/bin/sh
echo 4242
EOF
  chmod +x "$BIN/pgrep"
  [ "$(sh "$CTL" vmx-pid)" = 4242 ] || fail "vmx-pid prints the pid"
  teardown
}
case_setup() {
  setup
  cat > "$BIN/docker-machine-bootstrap" <<EOF
#!/bin/sh
: > "$WORK/bootstrap-ran"
EOF
  chmod +x "$BIN/docker-machine-bootstrap"
  sh "$CTL" setup || fail "setup exit 0"
  [ -f "$WORK/bootstrap-ran" ] || fail "setup execs docker-machine-bootstrap"
  teardown
}

case_packaging() {
  grep -q -- '--common' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh needs --common"
  grep -q -- '--ctl' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh needs --ctl"
  grep -q 'usr/local/libexec/mavergreen/docker/docker-machine-common.sh' "$ROOT/cmake/package_pkg.sh" \
    || fail "package_pkg.sh must install docker-machine-common.sh"
  grep -q 'usr/local/bin/docker-machine-ctl' "$ROOT/cmake/package_pkg.sh" \
    || fail "package_pkg.sh must install docker-machine-ctl"
  grep -q -- '--common payload/docker-machine-common.sh' "$ROOT/.github/workflows/release.yml" \
    || fail "release.yml must pass --common"
  grep -q -- '--ctl payload/docker-machine-ctl' "$ROOT/.github/workflows/release.yml" \
    || fail "release.yml must pass --ctl"
  grep -q 'usr/local/bin/docker-machine-migrate' "$ROOT/cmake/package_pkg.sh" \
    || fail "package_pkg.sh must install docker-machine-migrate"
  grep -q -- '--migrate payload/docker-machine-migrate' "$ROOT/.github/workflows/release.yml" \
    || fail "release.yml must pass --migrate"
  echo "  ctl-packaging OK"
}

# A run that can publish must be ALONE in its concurrency group. The old shape here was the opposite:
# all dispatches shared one group with cancel-in-progress:false, sold as a version-bump lock. It never
# locked anything -- cancel-in-progress:false protects the RUNNING run, not a QUEUED one, and GitHub
# keeps only the newest pending run per group. A third dispatch cancels the queued second (verified
# 2026-09-09). Two dispatches may now compute the same -mavericks.(N+1); shipyard's publish-release.yml
# refuses the loser at publish time, which is loud where the old shape was silent.
case_release_concurrency() {
  RY="$ROOT/.github/workflows/release.yml"
  grep -qF "github.event_name == 'pull_request'" "$RY" \
    || fail "release.yml: the concurrency group must single out pull_request -- it is the only event that supersedes"
  grep -qF "github.run_id" "$RY" \
    || fail "release.yml: pushes, tags and dispatches must be keyed per RUN, so a publishing run is alone in its group"
  grep -qF "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$RY" \
    || fail "release.yml: only a pull_request may be cancelled by a superseding run"
  # the shape this replaced, in either of its spellings
  if grep -qF "workflow_dispatch' && 'local_release'" "$RY" \
     || grep -qF "cancel-in-progress: \${{ github.event_name != 'workflow_dispatch' }}" "$RY"; then
    fail "release.yml: the shared-dispatch-group 'lock' is back -- it silently evicts queued releases"
  fi
  echo "  release-concurrency OK"
}

# CLI-first image roll: image-status echoes current/stale/absent; image-upgrade repoints a stale
# Boot2DockerURL (Wowfunhappy-migrated hosts hold the vanished DMG path) THEN `docker-machine upgrade`
# and heals. No GUI in the loop — the menu-bar app just shells out to these.
case_image() {
  setup; stub_dm Running
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"; mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  export MAVERICKS_DOCKER_ISO="$WORK/installed.iso"; printf 'NEW\n' > "$MAVERICKS_DOCKER_ISO"
  printf 'OLD\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/boot2docker.iso"
  printf '{ "Boot2DockerURL": "/Volumes/Docker for Mavericks/boot2docker.iso" }\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json"
  [ "$(sh "$CTL" image-status)" = stale ] || fail "image-status must report stale when the VM iso differs"
  sh "$CTL" image-upgrade >/dev/null || fail "image-upgrade exit 0 on success"
  grep -q "\"Boot2DockerURL\": \"$MAVERICKS_DOCKER_ISO\"" "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json" \
    || fail "image-upgrade must repoint Boot2DockerURL to the installed ISO before upgrading"
  grep -q '^upgrade container-tools' "$DM_LOG" || fail "image-upgrade must call docker-machine upgrade"
  grep -q '^start container-tools' "$DM_LOG" || fail "image-upgrade must start the VM after upgrading"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "image-upgrade must release op.lock"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state")" = running ] || fail "image-upgrade must settle state to running"
  teardown
}

# A failing `docker-machine upgrade` must (1) make the verb exit non-zero so the app can notify
# failure, and (2) still start the VM so the user is not left with a down machine.
case_image_upgrade_fails() {
  setup
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"; mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  export MAVERICKS_DOCKER_ISO="$WORK/installed.iso"; printf 'NEW\n' > "$MAVERICKS_DOCKER_ISO"
  printf 'OLD\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/boot2docker.iso"
  printf '{ "Boot2DockerURL": "/x" }\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/config.json"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status)  echo Running ;;
  upgrade) exit 3 ;;
  *)       exit 0 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$CTL" image-upgrade >/dev/null && fail "image-upgrade must exit non-zero when upgrade fails"
  grep -q '^start container-tools' "$DM_LOG" || fail "a failed upgrade must still start the VM"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "op.lock must be released even on failure"
  teardown
}

# A ctl verb announces working:<op> while it runs; verified here via op_end's cleanup (lock gone,
# state settled). The mid-run working marker itself is exercised in docker_common_test.
case_start_announces() {
  setup; stub_dm Running
  sh "$CTL" start >/dev/null || fail "start exit 0"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "start must release op.lock when done"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state")" = running ] || fail "start must settle state to running"
  teardown
}

case_status
case_start_stop
case_image
case_image_upgrade_fails
case_start_announces
case_start_syncs_context
case_status_stays_fast
case_login
case_vmxpid
case_setup
case_packaging
case_release_concurrency
echo "docker_ctl_test: OK"
