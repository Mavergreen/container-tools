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
  export NOTIFY_LOG="$WORK/notify.args"; : > "$NOTIFY_LOG"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$NOTIFY_LOG" > "$BIN/notifyutil"; chmod +x "$BIN/notifyutil"
  OLDPATH=$PATH; PATH="$BIN:$PATH"
  # osascript stub: record args (used for notifications + Terminal)
  cat > "$BIN/osascript" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$OSA_LOG"
EOF
  chmod +x "$BIN/osascript"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }
# The shell no longer writes the menu's cache files (2026-11-23): it posts a notification and the
# menu asks overview-status. announced = a change notification went out; sw = announced + the word.
NOTE=dev.mavergreen.container-tools.changed
announced() { grep -q -- "-p $NOTE" "$NOTIFY_LOG"; }
sw() { announced || { echo NOT-ANNOUNCED; return; }; ( . "${MAVERICKS_DOCKER_COMMON:-$COMMON}"; status_word ); }
no_caches() { for _f in state readiness disk; do [ -e "$MAVERICKS_DOCKER_STATE_DIR/$_f" ] && return 1; done; return 0; }

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

# A VM the user stopped from the menu (ctl stop) stays stopped: the login agent's 60s tick must not
# start it again. Only within the boot the stop happened in -- after a reboot, auto-start resumes.
stub_stopped_vm() {
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
}
case_user_stopped_stays_stopped() {
  setup; make_docker; stub_stopped_vm
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR"
  echo boot-A > "$MAVERICKS_DOCKER_STATE_DIR/user-stopped"
  MAVERICKS_DOCKER_BOOT_ID=boot-A sh "$BOOT" || fail "user-stopped tick should exit 0"
  [ -f "$WORK/started" ] && fail "the login agent restarted a VM the user stopped (the menu's Stop must stick)"
  [ "$(sw)" = stopped ] || fail "a user-stopped tick should announce 'stopped'"
  teardown
}
case_user_stopped_previous_boot() {
  setup; make_docker; stub_stopped_vm
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR"
  echo boot-A > "$MAVERICKS_DOCKER_STATE_DIR/user-stopped"
  MAVERICKS_DOCKER_BOOT_ID=boot-B sh "$BOOT" || fail "after-reboot tick should exit 0"
  [ -f "$WORK/started" ] || fail "a stop from a previous boot must not keep the VM down after a reboot"
  [ -f "$MAVERICKS_DOCKER_STATE_DIR/user-stopped" ] && fail "a stale user-stopped marker should be removed"
  teardown
}

case_user_stopped_stays_stopped
case_user_stopped_previous_boot

# The login agent's tick keeps the menu's disk numbers fresh, and says once a day when the VM's
# disk is nearly full -- the 2026-09-24 crash-loop gave no sign at all from the Mac.
stub_running_vm_df() { # $1 = df's data line
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  ssh)    echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'; echo "$1" ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
}
case_tick_refreshes_disk() {
  setup; make_docker; stub_running_vm_df '/dev/sda1 18668944 12460804 5219012 70% /mnt/sda1'
  sh "$BOOT" || fail "tick should exit 0"
  no_caches || fail "the tick must not write the menu's cache files"
  grep -q 'almost full' "$OSA_LOG" && fail "a 70% disk must not notify"
  teardown
}
case_tick_warns_low_disk() {
  setup; make_docker; stub_running_vm_df '/dev/sda1 18668944 16000000 1700000 91% /mnt/sda1'
  sh "$BOOT" || fail "tick should exit 0"
  grep -q 'almost full' "$OSA_LOG" || fail "a low disk must notify"
  : > "$OSA_LOG"
  sh "$BOOT" || fail "second tick should exit 0"
  grep -q 'almost full' "$OSA_LOG" && fail "the low-disk notification must be throttled to once a day"
  teardown
}

case_tick_refreshes_disk
case_tick_warns_low_disk

# The tick records readiness for the menu (running is power; the menu should say "Finishing setup" or
# "Needs attention" while Docker itself doesn't answer).
case_tick_records_readiness() {
  setup; stub_running_vm_df '/dev/sda1 18668944 12460804 5219012 70% /mnt/sda1'
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$*" in *" info"*) echo 23.0.6 ;; *"context inspect"*) exit 1 ;; esac
exit 0
EOF
  chmod +x "$BIN/docker"
  sh "$BOOT" || fail "tick should exit 0"
  announced || fail "the tick must announce"; no_caches || fail "the tick must not write a readiness file"
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$*" in *" info"*) echo 'x509: certificate signed by unknown authority' >&2; exit 1 ;; *"context inspect"*) exit 1 ;; esac
exit 0
EOF
  chmod +x "$BIN/docker"
  sh "$BOOT" || fail "tick should exit 0"
  no_caches || fail "the tick must not write a readiness file"
  grep -q regenerate-certs "$DM_LOG" && fail "the tick must never regenerate certs by itself"
  teardown
}
case_tick_records_readiness

# A low disk is first helped automatically, with only what is safe unattended: dangling images (no
# -a: never a tagged image, which may be impossible to rebuild) and build cache. Never containers or
# volumes. At most once every 6 hours, under op.lock, and the notification only if still low.
# The df stub reads low until the docker stub has pruned, when $1 = fixes.
stub_vm_pruning() { # $1 = fixes | stays-low
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  ssh)    echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
          if [ "$1" = fixes ] && [ -f "$WORK/pruned" ]; then echo '/dev/sda1 18668944 12460804 5219012 70% /mnt/sda1'
          else echo '/dev/sda1 18668944 16000000 1700000 91% /mnt/sda1'; fi ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  cat > "$BIN/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DOCKER_LOG"
case "\$*" in
  *"context inspect"*) exit 1 ;;
  *prune*) [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] || echo "prune without op.lock" >> "$WORK/violations"
           touch "$WORK/pruned" ;;
esac
exit 0
EOF
  chmod +x "$BIN/docker"
}
PRUNES() { grep -c 'prune' "$DOCKER_LOG" || true; }
case_tick_auto_frees_low_disk() {
  setup; stub_vm_pruning fixes
  sh "$BOOT" || fail "tick should exit 0"
  grep -qx -- '--context mavericks image prune -f' "$DOCKER_LOG" || fail "a low disk must prune dangling images"
  grep -qx -- '--context mavericks builder prune -f' "$DOCKER_LOG" || fail "a low disk must prune build cache"
  grep -q -- 'prune -a\|--all' "$DOCKER_LOG" && fail "unattended pruning must never remove tagged images (-a)"
  grep -E -q -e 'volume' -e 'container prune' -e 'system prune' "$DOCKER_LOG" && fail "unattended pruning must never touch containers or volumes"
  [ -f "$WORK/violations" ] && fail "pruning must hold op.lock: $(cat "$WORK/violations")"
  [ -d "$MAVERICKS_DOCKER_STATE_DIR/op.lock" ] && fail "auto-free must release op.lock"
  no_caches || fail "auto-free must not write the disk cache"
  grep -q 'almost full' "$OSA_LOG" && fail "no notification when auto-free brought the disk back from low"
  grep -q 'auto-free' "$MAVERICKS_DOCKER_LOG" || fail "auto-free must say in the log what it did"
  teardown
}
case_tick_auto_free_still_low_notifies() {
  setup; stub_vm_pruning stays-low
  sh "$BOOT" || fail "tick should exit 0"
  [ "$(PRUNES)" -eq 2 ] || fail "a low disk must be pruned once (got $(PRUNES) prunes)"
  grep -q 'almost full' "$OSA_LOG" || fail "still low after auto-free: notify"
  grep -q 'system df' "$DOCKER_LOG" || fail "still low after auto-free: the notification says what fills the disk (disk_advice)"
  teardown
}
case_tick_auto_free_rate_limited() {
  setup; stub_vm_pruning stays-low
  sh "$BOOT" || fail "tick should exit 0"
  : > "$DOCKER_LOG"
  sh "$BOOT" || fail "second tick should exit 0"
  [ "$(PRUNES)" -eq 0 ] || fail "auto-free must not run again within 6 hours"
  grep -q 'system df' "$DOCKER_LOG" && fail "once today's low-disk notification has fired, the tick must not build its advice again"
  echo $(( $(date +%s) - 6 * 3600 - 1 )) > "$MAVERICKS_DOCKER_STATE_DIR/auto-free-last"
  sh "$BOOT" || fail "third tick should exit 0"
  [ "$(PRUNES)" -eq 2 ] || fail "auto-free must run again once 6 hours have passed"
  teardown
}

case_tick_auto_frees_low_disk
case_tick_auto_free_still_low_notifies
case_tick_auto_free_rate_limited

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
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/creating.lock"  # portability-ok: pre-creates a held lock for the test; no race
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
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/creating.lock"  # portability-ok: pre-creates a held lock for the test; no race
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
  [ "$(MAVERICKS_DOCKER_TEST_STATUS=Running sw)" = running ] \
    || fail "bootstrap must announce 'running'"
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
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"  # portability-ok: pre-creates a held lock for the test; no race
  printf 'stop\n' > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"
  sh "$BOOT" || fail "should exit 0 when an op is in progress"
  [ -f "$WORK/started" ] && fail "bootstrap must NOT start the VM while an op holds op.lock"
  [ "$(sw)" = "working:stop" ] \
    || fail "bootstrap must announce working:<op> while an op is in progress"
  teardown
}

case_op_in_progress_skips

# --- Case: VMware paused the VM for host disk space -> say so, and leave the machine alone ---
# Every docker-machine command waits on the pause, so a tick that starts the VM only piles on.
# The state and a notification say what to do. Holds even while an op owns the machine.
case_host_disk_full() {
  setup; make_docker
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in status) echo Stopped ;; start) : > "$WORK/started" ;; esac
EOF
  chmod +x "$BIN/docker-machine"
  printf '#!/bin/sh\necho 4242\n' > "$BIN/pgrep"; chmod +x "$BIN/pgrep"
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S').284-05:00| vmx| I125: MsgQuestion: msg.mainMemPosix.noSpaceBasic reply=0" \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/vmware.log"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"  # portability-ok: pre-creates a held lock for the test; no race
  printf 'image-upgrade\n' > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"
  sh "$BOOT" || fail "should exit 0 when the host disk is full"
  [ -f "$WORK/started" ] && fail "bootstrap must NOT start a VM VMware has paused"
  [ "$(sw)" = host-disk-full ] \
    || fail "bootstrap must announce host-disk-full"
  grep -q "display notification.*Mac's disk" "$OSA_LOG" || fail "bootstrap must notify that the Mac's disk is full"
  teardown
}

case_host_disk_full

# --- Case: no room on the Mac to power a stopped VM on -> don't start it into a pause ---
case_no_room_to_boot() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "16384"\n' > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 1 1 3000000 99%% /"\n' \
    > "$BIN/df"; chmod +x "$BIN/df"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$DM_LOG"
case "\$1" in status) echo Stopped ;; start) : > "$WORK/started" ;; esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "should exit 0"
  [ -f "$WORK/started" ] && fail "bootstrap must NOT start a VM the Mac has no room to power on"
  [ "$(sw)" = host-disk-full ] \
    || fail "bootstrap must announce host-disk-full when there is no room to start"
  grep -q "display notification.*GB free" "$OSA_LOG" || fail "bootstrap must say how much space starting needs"
  [ -f "$MAVERICKS_DOCKER_STATE_DIR/boot-refused" ] || fail "the refusal must be remembered (boot-refused), so the menu keeps saying why"
  printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/x 1 1 900000000 1%% /"\n' \
    > "$BIN/df"; chmod +x "$BIN/df"
  sh "$BOOT" || fail "should exit 0"
  [ -f "$WORK/started" ] || fail "with room again, the tick starts the VM"
  [ -f "$MAVERICKS_DOCKER_STATE_DIR/boot-refused" ] && fail "a start must forget the refusal"
  teardown
}

case_no_room_to_boot

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
  [ "$(MAVERICKS_DOCKER_TEST_STATUS=Running sw)" = running ] \
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

# --- Task 4: GUI resource advisory after a successful fresh create ---

# Case: fresh create with 1024 MiB / 1 vCPU -> once/day gui-resources advisory fires.
# The 2 GiB/two-vCPU baseline matches Task 2's check_gui_resources() threshold.
case_fresh_create_gui_advisory() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "1024"\nnumvcpus = "1"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) [ -f "$WORK/created" ] && { echo Stopped; exit 0; }; exit 1 ;;
  create) : > "$WORK/created" ;;
  start)  : > "$WORK/started" ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
  inspect) exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "fresh-create advisory path should exit 0"
  grep -q '2 GiB' "$OSA_LOG" || fail "expected gui-resources advisory mentioning 2 GiB after fresh create with 1024 MiB/1 vCPU"
  teardown
}

# Case: fresh create at baseline (2048 MiB / 2 vCPUs) -> no advisory.
case_fresh_create_at_baseline_no_advisory() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "2048"\nnumvcpus = "2"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) [ -f "$WORK/created" ] && { echo Stopped; exit 0; }; exit 1 ;;
  create) : > "$WORK/created" ;;
  start)  : > "$WORK/started" ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
  inspect) exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "baseline create path should exit 0"
  grep -q '2 GiB' "$OSA_LOG" && fail "must not emit gui-resources advisory when at or above the 2 GiB baseline"
  teardown
}

# Case: fresh create with unknown resource report (no VMX, driver inspect fails) -> no advisory.
case_fresh_create_unknown_no_advisory() {
  setup; make_docker
  # No VMX file; docker-machine inspect returns nothing -> resource_status returns unknown.
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status)  [ -f "$WORK/created" ] && { echo Stopped; exit 0; }; exit 1 ;;
  create)  : > "$WORK/created" ;;
  start)   : > "$WORK/started" ;;
  env)     echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
           echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
  inspect) exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "fresh-create unknown-resources path should exit 0"
  grep -q '2 GiB' "$OSA_LOG" && fail "must not emit gui-resources advisory when resource_status is unknown"
  teardown
}

# Case: once/day throttle -- pre-stamp today's date so notify returns early.
case_gui_advisory_throttled() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "1024"\nnumvcpus = "1"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) [ -f "$WORK/created" ] && { echo Stopped; exit 0; }; exit 1 ;;
  create) : > "$WORK/created" ;;
  start)  : > "$WORK/started" ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
  inspect) exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR"
  date '+%Y-%m-%d' > "$MAVERICKS_DOCKER_STATE_DIR/notified-gui-resources"
  sh "$BOOT" || fail "fresh-create with pre-stamped advisory should exit 0"
  grep -q '2 GiB' "$OSA_LOG" && fail "gui-resources advisory must be throttled when already notified today"
  teardown
}

case_fresh_create_gui_advisory
case_fresh_create_at_baseline_no_advisory
case_fresh_create_unknown_no_advisory
case_gui_advisory_throttled

# --- Fix: advisory covers the interactive create path and only fires on a successful create ---

# Case: interactive create assembles a _cmd whose re-exec carries MAVERICKS_DOCKER_JUST_CREATED=1.
case_interactive_create_cmd_has_marker() {
  setup; make_docker
  unset MAVERICKS_DOCKER_NONINTERACTIVE
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in status) exit 1 ;; esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "interactive create should exit 0"
  grep -q 'MAVERICKS_DOCKER_JUST_CREATED=1' "$OSA_LOG" \
    || fail "interactive create _cmd must carry MAVERICKS_DOCKER_JUST_CREATED=1 for the re-exec"
  teardown
}

# Case: re-exec with marker set + 1024/1 VMX -> advisory fires.
case_just_created_marker_low_res_advises() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "1024"\nnumvcpus = "1"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status)  echo Stopped ;;
  start)   : > "$WORK/started" ;;
  env)     echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
           echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
  inspect) exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  MAVERICKS_DOCKER_JUST_CREATED=1 sh "$BOOT" || fail "re-exec with marker should exit 0"
  grep -q '2 GiB' "$OSA_LOG" \
    || fail "expected gui-resources advisory when JUST_CREATED marker is set and VM has 1024 MiB/1 vCPU"
  teardown
}

# Case: re-exec with marker set + unknown resource report -> no advisory.
case_just_created_marker_unknown_no_advice() {
  setup; make_docker
  # No VMX, inspect fails -> resource_status returns unknown.
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status)  echo Stopped ;;
  start)   : > "$WORK/started" ;;
  env)     echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
           echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
  inspect) exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  MAVERICKS_DOCKER_JUST_CREATED=1 sh "$BOOT" || fail "re-exec marker unknown-resources should exit 0"
  grep -q '2 GiB' "$OSA_LOG" \
    && fail "must not emit gui-resources advisory when resource_status is unknown even with JUST_CREATED marker"
  teardown
}

# Case: noninteractive create where docker-machine create exits 1 -> no advisory.
case_noninteractive_failed_create_no_advice() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "1024"\nnumvcpus = "1"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status)  exit 1 ;;
  create)  exit 1 ;;
  inspect) exit 1 ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "failed noninteractive create should exit 0"
  grep -q '2 GiB' "$OSA_LOG" \
    && fail "must not emit gui-resources advisory when docker-machine create fails"
  teardown
}

case_interactive_create_cmd_has_marker
case_just_created_marker_low_res_advises
case_just_created_marker_unknown_no_advice
case_noninteractive_failed_create_no_advice

# --- Case: existing running low-resource VM without JUST_CREATED marker -> no advisory ---
# A routine login-agent tick on a VM the user has had for a while must not spam the notification.
case_existing_running_no_advice() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "1024"\nnumvcpus = "1"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Running ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "existing running VM should exit 0"
  grep -q '2 GiB' "$OSA_LOG" \
    && fail "must not emit gui-resources advisory for an existing running VM without JUST_CREATED marker"
  teardown
}

# --- Case: existing stopped low-resource VM without JUST_CREATED marker -> no advisory, but starts ---
case_existing_stopped_no_advice() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "1024"\nnumvcpus = "1"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Stopped ;;
  start)  : > "$WORK/started" ;;
  env)    echo 'export DOCKER_HOST="tcp://192.168.237.131:2376"'
          echo "export DOCKER_CERT_PATH=\"$HOME/x\"" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  sh "$BOOT" || fail "existing stopped VM should exit 0"
  grep -q '2 GiB' "$OSA_LOG" \
    && fail "must not emit gui-resources advisory for an existing stopped VM without JUST_CREATED marker"
  [ -f "$WORK/started" ] || fail "a stopped VM without user-stopped marker must be started"
  teardown
}

# --- Case: create lock held + JUST_CREATED marker -> no advisory, no start/stop/create ---
case_create_lock_with_marker_no_advice() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "1024"\nnumvcpus = "1"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in status) exit 1 ;; esac
EOF
  chmod +x "$BIN/docker-machine"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/creating.lock"
  MAVERICKS_DOCKER_JUST_CREATED=1 sh "$BOOT" || fail "create lock + JUST_CREATED marker should exit 0"
  grep -q '2 GiB' "$OSA_LOG" \
    && fail "must not emit gui-resources advisory when create lock is held"
  grep -qE 'start|stop|create' "$DM_LOG" \
    && fail "must not call start/stop/create when create lock is held"
  teardown
}

# --- Case: op lock held + JUST_CREATED marker -> no advisory, no start ---
case_op_lock_with_marker_no_advice() {
  setup; make_docker
  mkdir -p "$MAVERICKS_DOCKER_MACHDIR/container-tools"
  printf 'memsize = "1024"\nnumvcpus = "1"\n' \
    > "$MAVERICKS_DOCKER_MACHDIR/container-tools/container-tools.vmx"
  cat > "$BIN/docker-machine" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$DM_LOG"
case "\$1" in
  status) echo Stopped ;;
  start)  : > "$WORK/started" ;;
esac
EOF
  chmod +x "$BIN/docker-machine"
  mkdir -p "$MAVERICKS_DOCKER_STATE_DIR/op.lock"
  printf 'stop\n' > "$MAVERICKS_DOCKER_STATE_DIR/op.lock/name"
  MAVERICKS_DOCKER_JUST_CREATED=1 sh "$BOOT" || fail "op lock + JUST_CREATED marker should exit 0"
  grep -q '2 GiB' "$OSA_LOG" \
    && fail "must not emit gui-resources advisory when op lock is held"
  [ -f "$WORK/started" ] && fail "must not start VM while op lock is held"
  teardown
}

case_existing_running_no_advice
case_existing_stopped_no_advice
case_create_lock_with_marker_no_advice
case_op_lock_with_marker_no_advice

echo "docker_bootstrap_test: OK"
