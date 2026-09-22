# ONE-TIME MIGRATION off the ModernMavericks identity (flag day 2026-09-22: the org became Mavergreen,
# and every installed identifier moved from dev.modernmavericks.* to dev.mavergreen.*).
# DELETABLE once no pre-flag-day install survives (see shipyard SKILL.md "Consolidation backlog").
#
# Staged beside the postinstall as flagday.sh and sourced by it, which then calls
# ct_flagday_retire "$3". Defines functions only; contains no `exit` and prefixes its variables, so
# sourcing it cannot end or disturb the caller. Best-effort throughout: it never fails the install.
#
# Installer never removes what a newer payload no longer carries, and the changed pkg identifier makes
# this a different package, so this retires what the old identity left on the target volume ($3):
#   - the VM LaunchAgent dev.modernmavericks.container-tools-machine: unloaded from the console user's
#     session (boot volume only) and its plist removed. The new agent has a new Label, so launchd's
#     record of a user having turned "Start Docker at Login" off (unload -w, kept under the OLD Label)
#     does not carry over by itself: it is read here and re-applied to the new Label, and
#     CT_FLAGDAY_LOGIN_OFF=1 tells the caller not to load the new agent.
#   - /usr/local/libexec/modernmavericks/docker and /usr/local/share/modernmavericks/container-tools,
#     which only this pkg installs (superseded by .../mavergreen/...); their parents go only if empty.
#   - the receipt of the old pkg identifier dev.modernmavericks.container-tools.
# NOT here: the old updater app and its update-check agent (shipyard's agent-load snippet, which this
# postinstall already runs, retires those); each user's state and log dirs (moved at runtime by
# docker-machine-common.sh, for every user); the menu-bar app's preferences (copied by the app).
# Old names are spelled out in full on purpose: a mechanical rename must not turn them into new ones.

# Was the old VM agent disabled for this uid? launchd keeps that per user, under the Label: 10.9 in
# launchd.db's per-user overrides.plist (<label> = { Disabled = true }), 10.10+ in
# com.apple.xpc.launchd's disabled.<uid>.plist (<label> = true).
ct_flagday_login_was_off() { # root uid
  _ct_fd_old=dev.modernmavericks.container-tools-machine
  _ct_fd_db="$1/private/var/db"
  [ "$(/usr/libexec/PlistBuddy -c "Print :$_ct_fd_old:Disabled" \
      "$_ct_fd_db/launchd.db/com.apple.launchd.peruser.$2/overrides.plist" 2>/dev/null)" = true ] && return 0
  [ "$(/usr/libexec/PlistBuddy -c "Print :$_ct_fd_old" \
      "$_ct_fd_db/com.apple.xpc.launchd/disabled.$2.plist" 2>/dev/null)" = true ] && return 0
  return 1
}

ct_flagday_retire() { # target-volume ($3 of the postinstall)
  CT_FLAGDAY_LOGIN_OFF=0
  # With no target volume nothing is known about where the old install lives: remove nothing, never
  # an unanchored "/".
  [ -n "${1:-}" ] || { echo "container-tools: postinstall got no target volume; flag-day cleanup skipped" >&2; return 0; }
  _ct_fd_root="${1%/}"
  _ct_fd_old_plist="$_ct_fd_root/Library/LaunchAgents/dev.modernmavericks.container-tools-machine.plist"
  _ct_fd_new_plist=/Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist
  _ct_fd_uid=$(stat -f %u /dev/console 2>/dev/null || echo 0)
  _ct_fd_user=$(stat -f %Su /dev/console 2>/dev/null || echo root)

  # launchctl only when installing to the BOOT volume (root ""): it talks to the running system, not
  # to whatever disk the pkg was pointed at. CT_FLAGDAY_ASSUME_BOOT is the tests' seam for driving
  # this path against a fake volume with launchctl stubbed. Mirrors shipyard's agent-load: bootout /
  # disable are 10.10+, and on 10.9 the fallback must run as the console user, because a root
  # postinstall's own launchctl talks to root's session and not the Aqua one.
  if { [ -z "$_ct_fd_root" ] || [ "${CT_FLAGDAY_ASSUME_BOOT:-}" = 1 ]; } \
     && [ -f "$_ct_fd_old_plist" ] && [ "${_ct_fd_uid:-0}" -gt 0 ] && [ "$_ct_fd_user" != root ]; then
    if ct_flagday_login_was_off "$_ct_fd_root" "$_ct_fd_uid"; then
      CT_FLAGDAY_LOGIN_OFF=1
      launchctl disable gui/"$_ct_fd_uid"/dev.mavergreen.container-tools-machine 2>/dev/null \
        || sudo -u "$_ct_fd_user" launchctl unload -w "$_ct_fd_new_plist" 2>/dev/null \
        || true
    fi
    launchctl bootout gui/"$_ct_fd_uid" "$_ct_fd_old_plist" 2>/dev/null \
      || sudo -u "$_ct_fd_user" launchctl unload "$_ct_fd_old_plist" 2>/dev/null \
      || true
  fi
  rm -f "$_ct_fd_old_plist" 2>/dev/null \
    || echo "container-tools: could not remove the pre-rename VM agent $_ct_fd_old_plist" >&2

  rm -rf "$_ct_fd_root/usr/local/libexec/modernmavericks/docker" 2>/dev/null \
    || echo "container-tools: could not remove the pre-rename $_ct_fd_root/usr/local/libexec/modernmavericks/docker" >&2
  rmdir "$_ct_fd_root/usr/local/libexec/modernmavericks" 2>/dev/null || true
  rm -rf "$_ct_fd_root/usr/local/share/modernmavericks/container-tools" 2>/dev/null \
    || echo "container-tools: could not remove the pre-rename $_ct_fd_root/usr/local/share/modernmavericks/container-tools" >&2
  rmdir "$_ct_fd_root/usr/local/share/modernmavericks" 2>/dev/null || true

  pkgutil --volume "$1" --forget dev.modernmavericks.container-tools >/dev/null 2>&1 || true
  return 0
}
