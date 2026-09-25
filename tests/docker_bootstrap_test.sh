#!/bin/sh
# platform: macOS-only -- exercises docker-machine-bootstrap, which sources common.sh's BSD `stat -f %m`
# Behavioral tests for docker-machine-bootstrap via PATH stubs.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOOT="$ROOT/payload/docker-machine-bootstrap"
[ -f "$BOOT" ] || { echo "docker_bootstrap_test: helper missing" >&2; exit 1; }

fail() { echo "docker_bootstrap_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-boot.XXXXXX")
  BIN="$WORK/bin"; mkdir -p "$BIN"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state"
  export MAVERICKS_DOCKER_LOG="$WORK/boot.log"
  export MAVERICKS_DOCKER_ISO="$WORK/iso"; : > "$MAVERICKS_DOCKER_ISO"
  export MAVERICKS_DOCKER_NONINTERACTIVE=1
  export MAVERICKS_DOCKER_PROFILES="$HOME/.bash_profile"
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"
  export MAVERICKS_DOCKER_FUSION_PRESENT=1
  export MAVERICKS_DOCKER_COMMON="$ROOT/payload/docker-machine-common.sh"
  export DM_LOG="$WORK/dm.args"; : > "$DM_LOG"
  export DOCKER_LOG="$WORK/docker.args"; : > "$DOCKER_LOG"
  export OSA_LOG="$WORK/osa.args"; : > "$OSA_LOG"
  OLDPATH=$PATH; PATH="$BIN:$PATH"
  # osascript stub: record args (used for notifications + Terminal)
  cat > "$BIN/osascript" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$OSA_LOG"
EOF
  chmod +x "$BIN/osascript"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }

# docker-machine stub: \$1 status -> echoes \$MAVERICKS_DOCKER_TEST_STATUS (empty => exit 1);
# create/start/env recorded; env prints canned exports.
make_dm() {
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) [ -n "\${MAVERICKS_DOCKER_TEST_STATUS:-}" ] && { echo "\${MAVERICKS_DOCKER_TEST_STATUS}"; exit 0; }; exit 1 ;;
  env) echo 'export DOCKER_TLS_VERIFY="1"'
       echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
       echo "export DOCKER_CERT_PATH=\"$HOME/.docker/machine/machines/default\""
       echo 'export DOCKER_MACHINE_NAME="default"' ;;
  *) : ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
}
# docker stub: record args; context inspect exits 1 (no context yet) unless a marker exists.
make_docker() {
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$1 \$2" in
  "context inspect") [ -f "$WORK/ctx-exists" ] || exit 1 ;;
  *) : ;;
esac
EOF
  chmod +x "$BIN/docker"
}

# --- Case: Fusion absent -> notify, exit 0, no docker-machine calls ---
case_fusion_absent() {
  setup; make_dm; make_docker
  MAVERICKS_DOCKER_FUSION_PRESENT=0 MAVERICKS_DOCKER_TEST_STATUS= sh "$BOOT" || fail "should exit 0 when Fusion absent"
  [ -s "$DM_LOG" ] && fail "must not call docker-machine when Fusion absent"
  grep -q 'Fusion' "$OSA_LOG" || fail "expected a Fusion notification"
  teardown
}

case_fusion_absent

# --- Case: no machine -> create, then start ---
case_create() {
  setup; make_docker
  # status: absent (exit 1) on first call, Stopped after create
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) [ -f "$WORK/created" ] && { echo Stopped; exit 0; }; exit 1 ;;
  create) : > "$WORK/created" ;;
  start)  : > "$WORK/started" ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "create path should exit 0"
  grep -q 'create -d vmwarefusion' "$DM_LOG" || fail "expected docker-machine create"
  grep -q "container-tools" "$DM_LOG" || fail "create should target 'container-tools'"
  [ -f "$WORK/started" ] || fail "expected start after create"
  teardown
}

# --- Case: stopped -> start (no create) ---
case_start() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Stopped ;;
  start)  : > "$WORK/started" ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "start path should exit 0"
  grep -q 'create' "$DM_LOG" && fail "must not create an existing machine"
  [ -f "$WORK/started" ] || fail "expected start"
  teardown
}

case_create
case_start

# --- Case: running -> create context from docker-machine env, then use it ---
case_context_create() {
  setup; make_dm; make_docker
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "running path should exit 0"
  grep -q 'context create mavericks' "$DOCKER_LOG" || fail "expected context create"
  grep -q 'host=tcp://192.168.237.131:2376' "$DOCKER_LOG" || fail "context must carry env host"
  grep -q 'ca=.*/ca.pem' "$DOCKER_LOG" || fail "context must carry ca cert path"
  grep -q 'context use mavericks' "$DOCKER_LOG" || fail "expected context use"
  teardown
}

# --- Case: context exists with same host -> update skipped, still 'use' ---
case_context_current() {
  setup; make_dm
  : > "$WORK/ctx-exists"
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$1 \$2" in
  "context inspect")
    # --format present => return current host (matches env); else exit 0
    case "\$*" in *Endpoints*) echo 'tcp://192.168.237.131:2376' ;; esac ;;
esac
EOF
  chmod +x "$BIN/docker"
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "should exit 0"
  grep -q 'context update' "$DOCKER_LOG" && fail "must not update when host unchanged"
  grep -q 'context use mavericks' "$DOCKER_LOG" || fail "expected context use"
  teardown
}

# --- Case: env fails on a post-rename cert/IP mismatch -> regenerate-certs, retry, create context ---
# Regression for the 2026-07-27 dogfood finding: migrating default->container-tools gave the VM a new
# DHCP IP, so its TLS cert (issued for the old IP) failed validation and `docker-machine env` errored.
# sync_context bailed silently -> no context, migrated-but-unreachable VM. It must regenerate certs and
# retry ON THAT SPECIFIC error only (regenerate-certs restarts the daemon).
case_context_cert_regen() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  env)
    if [ -f "$WORK/regenerated" ]; then
      echo 'export DOCKER_HOST="tcp://192.168.237.137:2376"'
      echo "export DOCKER_CERT_PATH=\"\$HOME/x\""
    else
      echo 'Error checking TLS connection: certificate is valid for 192.168.237.131, not 192.168.237.137' >&2
      exit 1
    fi ;;
  regenerate-certs) : > "$WORK/regenerated" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "should exit 0"
  grep -q 'regenerate-certs' "$DM_LOG" || fail "expected regenerate-certs on a cert/IP mismatch"
  grep -q 'context create mavericks' "$DOCKER_LOG" || fail "context must be created after cert regen"
  teardown
}

# --- Safety: env fails for a NON-cert reason -> do NOT regenerate-certs (no gratuitous daemon restart) ---
case_context_env_fail_noncert() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  env) echo 'Host does not exist: "container-tools"' >&2; exit 1 ;;
  regenerate-certs) : > "$WORK/regenerated" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "should exit 0"
  grep -q 'regenerate-certs' "$DM_LOG" && fail "must NOT regenerate-certs (restarts daemon) for a non-cert failure"
  grep -q 'context create' "$DOCKER_LOG" && fail "no context when env cannot be resolved"
  teardown
}

# --- Safety: cert mismatch but regen doesn't fix it -> regen attempted EXACTLY once, graceful, no context ---
case_context_regen_ineffective() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  env) echo 'certificate is valid for 10.0.0.1, not 10.0.0.2' >&2; exit 1 ;;
  regenerate-certs) : ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "should exit 0 even if regen does not help"
  [ "$(grep -c 'regenerate-certs' "$DM_LOG")" = 1 ] || fail "regen must be attempted exactly once (no thrash)"
  grep -q 'context create' "$DOCKER_LOG" && fail "no context when env still fails after regen"
  teardown
}

case_context_create
case_context_current
case_context_cert_regen
case_context_env_fail_noncert
case_context_regen_ineffective

# --- Case: leftover eval line in profile -> commented out (reversible), with a backup ---
case_env_line_commented() {
  setup; make_dm; make_docker
  printf '%s\n' 'eval "$(docker-machine env default)"' > "$HOME/.bash_profile"
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "should exit 0"
  grep -q '^# Mavergreen' "$HOME/.bash_profile" || fail "expected the env line commented with a marker"
  grep -Eq '^[[:space:]]*eval "\$\(docker-machine env default\)"' "$HOME/.bash_profile" \
    && fail "the active eval line must be gone"
  [ -f "$HOME/.bash_profile.premigrate" ] || fail "expected a one-time backup of the profile"
  teardown
}

# --- Case: commenting the env line is idempotent (one marker, backup not re-taken) ---
case_env_line_comment_idempotent() {
  setup; make_dm; make_docker
  printf '%s\n' 'eval "$(docker-machine env default)"' > "$HOME/.bash_profile"
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "should exit 0 (run 1)"
  cp "$HOME/.bash_profile.premigrate" "$WORK/backup-after-run1"
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "should exit 0 (run 2)"
  n=$(grep -c '^# Mavergreen' "$HOME/.bash_profile")
  [ "$n" = 1 ] || fail "expected exactly one marker after two runs, got $n"
  cmp -s "$WORK/backup-after-run1" "$HOME/.bash_profile.premigrate" \
    || fail "backup must not be overwritten on the second run"
  teardown
}

# --- Case: clean profile -> no override notification ---
case_env_clean() {
  setup; make_dm; make_docker
  printf '%s\n' 'export PS1="$ "' > "$HOME/.bash_profile"
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "should exit 0"
  grep -q 'overrides' "$OSA_LOG" && fail "must not warn on a clean profile"
  teardown
}

case_env_line_commented
case_env_line_comment_idempotent
case_env_clean

# --- Case: interactive create -> Terminal do-script + lock acquired ---
case_interactive_create() {
  setup; make_docker
  unset MAVERICKS_DOCKER_NONINTERACTIVE
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in status) exit 1 ;; esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "interactive create should exit 0"
  grep -q 'do script' "$OSA_LOG" || fail "expected a Terminal do-script"
  grep -q 'docker-machine create' "$OSA_LOG" || fail "Terminal must run docker-machine create"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/creating.lock" ] || fail "interactive create must hold the lock"
  teardown
}

# --- Case: create already in progress (fresh lock) -> no second create ---
case_create_locked() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in status) exit 1 ;; esac
EOF
  chmod +x "$BIN/docker-machine"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/creating.lock"
  sh "$BOOT" || fail "should exit 0 when create locked"
  grep -q 'create' "$DM_LOG" && fail "must not create while lock held"
  grep -q 'docker-machine create' "$OSA_LOG" && fail "must not spawn create Terminal while lock held"
  teardown
}

# --- Case: stale lock (>10 min) -> reclaimed, create proceeds ---
case_stale_lock() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) [ -f "$WORK/created" ] && { echo Stopped; exit 0; }; exit 1 ;;
  create) : > "$WORK/created" ;;
  start)  : > "$WORK/started" ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/creating.lock"
  touch -t 200001010000 "$MAVERICKS_DOCKER_STATE_DIR/creating.lock"
  sh "$BOOT" || fail "should exit 0 on stale lock"
  grep -q 'create -d vmwarefusion' "$DM_LOG" || fail "stale lock must be reclaimed and create proceed"
  teardown
}

case_interactive_create
case_create_locked
case_stale_lock

# --- Case: packaging references are consistent ---
case_packaging() {
  grep -q '/usr/local/mavergreen/container-tools/bin/docker-machine-bootstrap' "$ROOT/payload/dev.mavergreen.container-tools-machine.plist" \
    || fail "plist must launch docker-machine-bootstrap"
  grep -q 'docker-machine-ensure-default' "$ROOT/payload/dev.mavergreen.container-tools-machine.plist" \
    && fail "plist still references the old guard"
  grep -q -- '--bootstrap' "$ROOT/cmake/package_pkg.sh" || fail "package_pkg.sh missing --bootstrap"
  grep -q 'install -m 0755 "\$BOOT"' "$ROOT/cmake/package_pkg.sh" \
    || fail "package_pkg.sh must install the bootstrap helper"
  grep -q -- '--ensure-guard' "$ROOT/cmake/package_pkg.sh" && fail "package_pkg.sh still has --ensure-guard"
  [ -f "$ROOT/payload/docker-machine-ensure-default" ] && fail "old guard file still present"
  grep -q -- '--bootstrap payload/docker-machine-bootstrap' "$ROOT/.github/workflows/release.yml" \
    || fail "release.yml must pass --bootstrap"
  echo "  packaging-consistency OK"
}

case_packaging

# --- Case: a running reconcile announces state ---
case_writes_state() {
  setup; make_dm; make_docker
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "should exit 0"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state" 2>/dev/null)" = running ] \
    || fail "bootstrap must write 'running' to the state file"
  teardown
}

case_writes_state

# --- Case: a ctl op holds op.lock -> the timer tick must NOT act on the machine ---
# A user-initiated start/stop/restart/image-upgrade owns the machine; a concurrent login-agent
# tick must not fight it (e.g. start the VM mid-stop). It should announce working:<op> and bail.
case_op_in_progress_skips() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in status) echo Stopped ;; start) : > "$WORK/started" ;; esac
EOF
  chmod +x "$BIN/docker-machine"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  printf 'stop\n' > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"
  sh "$BOOT" || fail "should exit 0 when an op is in progress"
  [ -f "$WORK/started" ] && fail "bootstrap must NOT start the VM while an op holds op.lock"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state" 2>/dev/null)" = "working:stop" ] \
    || fail "bootstrap must announce working:<op> while an op is in progress"
  teardown
}

case_op_in_progress_skips

# --- Case: a commented-out env line must NOT trigger the override warning ---
case_env_commented() {
  setup; make_dm; make_docker
  printf '%s\n' '# eval "$(docker-machine env default)"' > "$HOME/.bash_profile"
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "should exit 0"
  grep -q 'overrides' "$OSA_LOG" && fail "must not warn on a commented-out line"
  teardown
}

# --- Case: a state dir containing spaces works end to end (quoting) ---
case_space_in_state_dir() {
  setup; make_dm; make_docker
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state dir with spaces"
  MAVERICKS_DOCKER_TEST_STATUS=Running sh "$BOOT" || fail "should exit 0 with a spaced state dir"
  [ "$(cat "$MAVERICKS_DOCKER_STATE_DIR/state" 2>/dev/null)" = running ] \
    || fail "state must be written into the spaced state dir"
  teardown
}

case_env_commented
case_space_in_state_dir

# --- Case: a STOPPED legacy 'default' is auto-migrated, then container-tools starts ---
case_legacy_default_stopped_migrates() {
  setup; make_docker
  # container-tools absent until migrate runs; legacy 'default' present and Stopped.
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1 \$2" in
  "status default")         echo Stopped; exit 0 ;;
  "status container-tools") [ -f "$WORK/migrated" ] && { echo Stopped; exit 0; }; exit 1 ;;
  "start container-tools")  : > "$WORK/started" ;;
  status)                   exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  # migrate stub: records the call and flips container-tools into existence.
  cat > "$BIN/docker-machine-migrate" <<EOF
#!/bin/sh
printf 'MIGRATE-CALLED\n' >> "$DM_LOG"
: > "$WORK/migrated"
EOF
  chmod +x "$BIN/docker-machine-migrate"
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/default"
  sh "$BOOT" || fail "should exit 0 on stopped legacy default"
  grep -q 'MIGRATE-CALLED' "$DM_LOG" || fail "expected auto-migrate for a stopped 'default'"
  grep -q 'create -d vmwarefusion' "$DM_LOG" && fail "must not create a 2nd VM when default exists"
  [ -f "$WORK/started" ] || fail "expected container-tools to start after migrate"
  teardown
}

# --- Case: a RUNNING legacy 'default' is NOT auto-migrated; user is told to stop it ---
case_legacy_default_running_defers() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1 \$2" in
  "status default")         echo Running; exit 0 ;;
  "status container-tools") exit 1 ;;
  status)                   exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  cat > "$BIN/docker-machine-migrate" <<EOF
#!/bin/sh
printf 'MIGRATE-CALLED\n' >> "$DM_LOG"
EOF
  chmod +x "$BIN/docker-machine-migrate"
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/default"
  sh "$BOOT" || fail "should exit 0 on running legacy default"
  grep -q 'MIGRATE-CALLED' "$DM_LOG" && fail "must NOT migrate a running 'default'"
  grep -q 'create -d vmwarefusion' "$DM_LOG" && fail "must not create a 2nd VM"
  grep -q 'migrate' "$OSA_LOG" || fail "expected a notification to stop+migrate the running default"
  teardown
}

case_legacy_default_stopped_migrates
case_legacy_default_running_defers
echo "docker_bootstrap_test: OK"
