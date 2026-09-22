#!/bin/sh
# The flag-day (2026-09-22) migration off the ModernMavericks identity, both halves:
#   - the postinstall's cmake/flagday-postinstall.sh, driven against a FAKE target volume with
#     launchctl/sudo/pkgutil/stat stubbed on PATH (never the real /Library);
#   - docker-machine-common.sh's runtime move of each user's state and log dirs, under a fake $HOME.
# DELETABLE with the migration itself (see shipyard SKILL.md "Consolidation backlog").
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FD="$ROOT/cmake/flagday-postinstall.sh"
COMMON="$ROOT/payload/docker-machine-common.sh"
fail() { echo "flagday_migration_test: FAIL: $*" >&2; exit 1; }
PB=/usr/libexec/PlistBuddy

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/ct-flagday.XXXXXX")
  VOL="$WORK/vol"; BIN="$WORK/bin"; mkdir -p "$VOL" "$BIN"
  CALLS="$WORK/calls"; : > "$CALLS"
  for c in launchctl sudo pkgutil; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "%s"\nexit 0\n' "$c" "$CALLS" > "$BIN/$c"
  done
  # A console user logged in as uid 501.
  cat > "$BIN/stat" <<'EOF'
#!/bin/sh
case "$*" in *%Su*) echo alice ;; *%u*) echo 501 ;; *) exit 1 ;; esac
EOF
  chmod +x "$BIN"/*
  OLDPATH=$PATH; PATH="$BIN:$PATH"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }

old_install() { # lay down what a pre-flag-day container-tools left on the volume
  mkdir -p "$VOL/Library/LaunchAgents" "$VOL/usr/local/libexec/modernmavericks/docker" \
           "$VOL/usr/local/share/modernmavericks/container-tools"
  : > "$VOL/Library/LaunchAgents/dev.modernmavericks.container-tools-machine.plist"
  : > "$VOL/usr/local/libexec/modernmavericks/docker/docker-machine-common.sh"
  : > "$VOL/usr/local/share/modernmavericks/container-tools/boot2docker.iso"
}

retire() { # run the sourced function in a subshell, printing CT_FLAGDAY_LOGIN_OFF
  ( . "$FD"; ct_flagday_retire "$1"; echo "$CT_FLAGDAY_LOGIN_OFF" )
}

case_other_volume() {
  setup; old_install
  mkdir -p "$VOL/usr/local/libexec/modernmavericks/someone-else"   # not ours: its parent must stay
  off=$(retire "$VOL/")
  [ ! -e "$VOL/Library/LaunchAgents/dev.modernmavericks.container-tools-machine.plist" ] || fail "old VM agent plist not removed"
  [ ! -e "$VOL/usr/local/libexec/modernmavericks/docker" ] || fail "old libexec dir not removed"
  [ -d "$VOL/usr/local/libexec/modernmavericks/someone-else" ] || fail "removed a libexec dir that is not ours"
  [ ! -e "$VOL/usr/local/share/modernmavericks" ] || fail "old share dir (now empty) not removed"
  grep -q '^launchctl' "$CALLS" && fail "launchctl must not run for a non-boot volume"
  grep -q "^pkgutil --volume $VOL/ --forget dev.modernmavericks.container-tools\$" "$CALLS" \
    || fail "old receipt not forgotten on the target volume"
  [ "$off" = 0 ] || fail "login-off wrongly set"
  echo "  other-volume OK"; teardown
}

case_boot_login_on() {
  setup; old_install
  off=$(CT_FLAGDAY_ASSUME_BOOT=1 retire "$VOL")
  grep -q "^launchctl bootout gui/501 $VOL/Library/LaunchAgents/dev.modernmavericks.container-tools-machine.plist\$" "$CALLS" \
    || fail "old VM agent not unloaded from the console session"
  grep -q 'disable' "$CALLS" && fail "disabled the new agent for a user who never turned it off"
  [ "$off" = 0 ] || fail "login-off wrongly set"
  [ ! -e "$VOL/Library/LaunchAgents/dev.modernmavericks.container-tools-machine.plist" ] || fail "old VM agent plist not removed"
  echo "  boot, login on OK"; teardown
}

case_boot_login_off_109() {
  setup; old_install
  db="$VOL/private/var/db/launchd.db/com.apple.launchd.peruser.501"; mkdir -p "$db"
  $PB -c "Add :dev.modernmavericks.container-tools-machine dict" \
      -c "Add :dev.modernmavericks.container-tools-machine:Disabled bool true" "$db/overrides.plist" >/dev/null
  off=$(CT_FLAGDAY_ASSUME_BOOT=1 retire "$VOL")
  [ "$off" = 1 ] || fail "10.9 login-off not carried over"
  grep -q '^launchctl disable gui/501/dev.mavergreen.container-tools-machine$' "$CALLS" \
    || fail "new agent not disabled for the user who had turned it off"
  echo "  boot, login off (10.9 overrides) OK"; teardown
}

case_boot_login_off_1010() {
  setup; old_install
  db="$VOL/private/var/db/com.apple.xpc.launchd"; mkdir -p "$db"
  $PB -c "Add :dev.modernmavericks.container-tools-machine bool true" "$db/disabled.501.plist" >/dev/null
  off=$(CT_FLAGDAY_ASSUME_BOOT=1 retire "$VOL")
  [ "$off" = 1 ] || fail "10.10+ login-off not carried over"
  echo "  boot, login off (10.10+ disabled db) OK"; teardown
}

case_no_target() {
  setup; old_install
  retire "" >/dev/null 2>&1
  [ -e "$VOL/Library/LaunchAgents/dev.modernmavericks.container-tools-machine.plist" ] || fail "removed something with no target volume"
  [ -s "$CALLS" ] && fail "ran commands with no target volume"
  echo "  no-target OK"; teardown
}

case_postinstall_wiring() {
  pp="$ROOT/cmake/package_pkg.sh"
  grep -q 'flagday-postinstall.sh" "$scripts/flagday.sh"' "$pp" || fail "package_pkg.sh must stage flagday.sh beside the postinstall"
  grep -q 'ct_flagday_retire "\$3"' "$pp" || fail "postinstall must call ct_flagday_retire with its own \$3"
  grep -q 'CT_FLAGDAY_LOGIN_OFF" != 1' "$pp" || fail "postinstall must not load the new agent for a user who turned it off"
  # The migration must still name the OLD identity: a mechanical rename would silently break it.
  grep -q 'dev.modernmavericks.container-tools-machine' "$FD" || fail "flagday.sh lost the old agent Label"
  grep -q 'forget dev.modernmavericks.container-tools' "$FD" || fail "flagday.sh lost the old pkg identifier"
  grep -q 'libexec/modernmavericks/docker' "$FD" || fail "flagday.sh lost the old libexec path"
  echo "  postinstall wiring OK"
}

# --- runtime: each user's dirs, moved by docker-machine-common.sh ---
rt_setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/ct-flagday-rt.XXXXXX")
  export HOME="$WORK/home"; mkdir -p "$HOME"
  OLDS="$HOME/Library/Application Support/ModernMavericks/container-tools"
  NEWS="$HOME/Library/Application Support/Mavergreen/container-tools"
  OLDL="$HOME/Library/Logs/ModernMavericks/container-tools"
  NEWL="$HOME/Library/Logs/Mavergreen/container-tools"
}
src_common() { # prints the STATE_DIR the sourced file settled on
  ( unset MAVERICKS_DOCKER_STATE_DIR MAVERICKS_DOCKER_LOG MAVERICKS_DOCKER_OLD_STATE_DIR MAVERICKS_DOCKER_OLD_LOG_DIR
    . "$COMMON"; printf '%s\n' "$STATE_DIR" )
}

case_rt_moves() {
  rt_setup
  mkdir -p "$OLDS" "$OLDL"; echo running > "$OLDS/state"; echo 2026-09-01 > "$OLDS/notified-create"
  echo "old log line" > "$OLDL/bootstrap.log"
  sd=$(src_common)
  [ "$sd" = "$NEWS" ] || fail "STATE_DIR should be the new dir, got $sd"
  [ "$(cat "$NEWS/state")" = running ] || fail "state not moved"
  [ -f "$NEWS/notified-create" ] || fail "notification stamps not moved"
  [ ! -e "$OLDS" ] || fail "old state dir still there after the move"
  [ ! -e "$HOME/Library/Application Support/ModernMavericks" ] || fail "empty old parent not removed"
  grep -q "old log line" "$NEWL/bootstrap.log" || fail "log history not moved"
  grep -q "flag day: moved" "$NEWL/bootstrap.log" || fail "the move was not logged"
  [ ! -e "$HOME/Library/Logs/ModernMavericks" ] || fail "empty old log parent not removed"
  # Idempotent: a second run is a no-op.
  [ "$(src_common)" = "$NEWS" ] || fail "second run changed STATE_DIR"
  echo "  runtime move OK"; rm -rf "$WORK"
}

case_rt_both_exist() {
  rt_setup
  mkdir -p "$OLDS" "$NEWS"; echo old > "$OLDS/state"; echo new > "$NEWS/state"
  src_common >/dev/null
  [ "$(cat "$OLDS/state")" = old ] && [ "$(cat "$NEWS/state")" = new ] || fail "both-exist must touch neither"
  [ -f "$OLDS/NOT-MIGRATED.txt" ] || fail "both-exist must leave a note in the old dir"
  echo "  runtime both-exist OK"; rm -rf "$WORK"
}

case_rt_deferred() {
  rt_setup
  mkdir -p "$OLDS/op.lock"; echo working:stop > "$OLDS/state"
  sd=$(src_common)
  [ "$sd" = "$OLDS" ] || fail "an op in progress must defer the move and keep the old dir, got $sd"
  [ ! -e "$NEWS" ] || fail "deferred move must not create the new dir (it would block the later move)"
  rmdir "$OLDS/op.lock"
  [ "$(src_common)" = "$NEWS" ] || fail "move not done once the op finished"
  echo "  runtime deferred OK"; rm -rf "$WORK"
}

case_rt_seam_isolation() {
  rt_setup
  mkdir -p "$OLDS"; echo keep > "$OLDS/state"
  ( export MAVERICKS_DOCKER_STATE_DIR="$WORK/state" MAVERICKS_DOCKER_LOG="$WORK/log"
    unset MAVERICKS_DOCKER_OLD_STATE_DIR MAVERICKS_DOCKER_OLD_LOG_DIR; . "$COMMON" )
  [ "$(cat "$OLDS/state")" = keep ] || fail "an overridden STATE_DIR must never reach the default old location"
  echo "  runtime seam isolation OK"; rm -rf "$WORK"
}

[ -f "$FD" ] || fail "missing $FD"
if [ -x "$PB" ]; then
  case_other_volume
  case_boot_login_on
  case_boot_login_off_109
  case_boot_login_off_1010
  case_no_target
else
  echo "  (no $PB here: postinstall cases need macOS; skipped)"
fi
case_postinstall_wiring
case_rt_moves
case_rt_both_exist
case_rt_deferred
case_rt_seam_isolation
echo "flagday_migration_test: all OK"
