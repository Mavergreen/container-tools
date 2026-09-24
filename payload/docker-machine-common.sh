#!/bin/sh
# docker-machine-common.sh — shared constants + helpers for docker-machine-bootstrap
# and docker-machine-ctl. SOURCED, not executed. Honors the MAVERICKS_DOCKER_* test seams.

# The menu-bar app (and anything else launched by LaunchServices) runs with a minimal PATH
# — /usr/bin:/bin:/usr/sbin:/sbin — that omits the install bindir. A bare `docker-machine`/
# `docker` then fails to resolve, so every verb driven from the GUI silently misreports:
# status_word() -> "absent" while the VM is really Stopped, and start/stop no-op. Guarantee
# our bindir is reachable regardless of the caller's PATH. Appended (not prepended) so a
# test/caller stub earlier on PATH still wins. Found dogfooding, 2026-07-29.
BINDIR=${MAVERICKS_DOCKER_BINDIR:-/usr/local/bin}
case ":$PATH:" in
  *:"$BINDIR":*) ;;
  *) PATH="$PATH:$BINDIR"; export PATH ;;
esac

MACHINE=container-tools
CONTEXT=mavericks
ISO=${MAVERICKS_DOCKER_ISO:-/usr/local/share/mavergreen/container-tools/boot2docker.iso}
LOG=${MAVERICKS_DOCKER_LOG:-$HOME/Library/Logs/Mavergreen/container-tools/bootstrap.log}
STATE_DIR=${MAVERICKS_DOCKER_STATE_DIR:-$HOME/Library/Application Support/Mavergreen/container-tools}
STATE_FILE="$STATE_DIR/state"
LOCK="$STATE_DIR/creating.lock"
OP_LOCK="$STATE_DIR/op.lock"   # generic in-progress marker for the ctl verbs (start/stop/restart/image-upgrade)
PROFILES=${MAVERICKS_DOCKER_PROFILES:-$HOME/.bash_profile $HOME/.profile $HOME/.zshrc $HOME/.bashrc}
AGENT_LABEL=dev.mavergreen.container-tools-machine
AGENT_PLIST=/Library/LaunchAgents/$AGENT_LABEL.plist
MACHDIR=${MAVERICKS_DOCKER_MACHDIR:-$HOME/.docker/machine/machines}

legacy_default_exists() { [ -d "$MACHDIR/default" ]; }

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null || true
}

notify() { # key title message  (throttled once/day per key)
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  _stamp="$STATE_DIR/notified-$1"; _today=$(date '+%Y-%m-%d')
  [ -f "$_stamp" ] && [ "$(cat "$_stamp" 2>/dev/null)" = "$_today" ] && return 0
  echo "$_today" > "$_stamp" 2>/dev/null || true
  osascript -e "display notification \"$3\" with title \"$2\"" >/dev/null 2>&1 || true
}

fusion_present() {
  [ "${MAVERICKS_DOCKER_FUSION_PRESENT:-}" = 0 ] && return 1
  [ "${MAVERICKS_DOCKER_FUSION_PRESENT:-}" = 1 ] && return 0
  [ -d "/Applications/VMware Fusion.app" ] || command -v vmrun >/dev/null 2>&1
}

machine_status() { docker-machine status "$MACHINE" 2>/dev/null; }

create_in_progress() {
  [ -d "$LOCK" ] || return 1
  _mt=$(stat -f %m "$LOCK" 2>/dev/null) || return 0
  if [ $(( $(date +%s) - _mt )) -gt 600 ]; then
    log "stale create lock; reclaiming"
    rmdir "$LOCK" 2>/dev/null || true
    return 1
  fi
  return 0
}

# op.lock is the ctl verbs' in-progress marker, kept SEPARATE from creating.lock on purpose:
# the create path's atomic-acquire + interactive/migrate flows depend on creating.lock, and
# folding the two buys only conceptual unity. Mirrors create_in_progress's 600s stale-reclaim.
op_in_progress() {
  [ -d "$OP_LOCK" ] || return 1
  _mt=$(stat -f %m "$OP_LOCK" 2>/dev/null) || return 0
  if [ $(( $(date +%s) - _mt )) -gt 600 ]; then
    log "stale op lock; reclaiming"
    rm -rf "$OP_LOCK" 2>/dev/null || true
    return 1
  fi
  return 0
}

op_name() { cat "$OP_LOCK/name" 2>/dev/null || echo working; }

op_begin() { # name  — announce a long op: create the lock and mark the state working:<name>
  _op=${1:-working}   # tolerate a zero-arg call under the callers' `set -u`
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  mkdir "$OP_LOCK" 2>/dev/null || true
  printf '%s\n' "$_op" > "$OP_LOCK/name" 2>/dev/null || true
  write_state "working:$_op"
}

op_end() { # release the lock and settle the state to the real machine status
  rm -rf "$OP_LOCK" 2>/dev/null || true
  write_state "$(status_word)"
}

# The single word the state file / menu bar cares about.
status_word() {
  fusion_present || { echo no-fusion; return; }
  create_in_progress && { echo creating; return; }
  op_in_progress && { echo "working:$(op_name)"; return; }
  case "$(machine_status)" in
    Running) echo running ;;
    Stopped) echo stopped ;;
    "")      echo absent ;;
    *)       echo error ;;
  esac
}

write_state() {
  # Atomic: write a temp then rename, so a reader (or the menu-bar app's kqueue watch)
  # never sees a truncated/empty file mid-write. The watcher re-arms on the rename.
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$1" > "$STATE_FILE.tmp" 2>/dev/null && mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null || true
}

# Re-point the 'mavericks' docker context at the VM's current endpoint, healing the two ways a
# DHCP renumber breaks it: a stale context host (so `docker` doesn't hang on the dead IP) and a
# TLS cert issued for the old IP. Detection uses `docker-machine env`, which reads docker-machine's
# OWN current-IP knowledge -- so it never hangs on the stale context. Cert regen is gated to that
# specific error only (regenerate-certs restarts the daemon, so never for transient/unreachable
# failures). Found dogfooding the default->container-tools migration, 2026-07-27. Shared by
# docker-machine-bootstrap (timer/login) and docker-machine-ctl (start/restart/status).
sync_context() {
  _env=$(docker-machine env "$MACHINE" 2>/dev/null)
  if [ -z "$_env" ] && docker-machine env "$MACHINE" 2>&1 | grep -q 'certificate is valid for'; then
    log "cert/IP mismatch on $MACHINE (a rename gave it a new IP); regenerating certs"
    docker-machine regenerate-certs -f "$MACHINE" >>"$LOG" 2>&1 || true
    _env=$(docker-machine env "$MACHINE" 2>/dev/null)
  fi
  [ -n "$_env" ] || return 0
  DOCKER_HOST=; DOCKER_CERT_PATH=
  eval "$_env" 2>/dev/null || return 0
  [ -n "${DOCKER_HOST:-}" ] || return 0
  _spec="host=$DOCKER_HOST,ca=$DOCKER_CERT_PATH/ca.pem,cert=$DOCKER_CERT_PATH/cert.pem,key=$DOCKER_CERT_PATH/key.pem"
  if docker context inspect "$CONTEXT" >/dev/null 2>&1; then
    _cur=$(docker context inspect "$CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
    if [ "$_cur" != "$DOCKER_HOST" ]; then
      docker context update "$CONTEXT" --docker "$_spec" >>"$LOG" 2>&1 || true
      log "context host -> $DOCKER_HOST"
    fi
  else
    docker context create "$CONTEXT" --docker "$_spec" >>"$LOG" 2>&1 || true
    log "context created -> $DOCKER_HOST"
  fi
  docker context use "$CONTEXT" >>"$LOG" 2>&1 || true
}

# A host copies boot2docker.iso at `docker-machine create` and boots that copy forever, so a package
# update that refreshes $ISO doesn't reach the VM until `docker-machine upgrade`. Compare the VM's
# booted image to the freshly-installed one. Echoes current | stale | absent (no VM / no installed
# ISO to compare). Pure CLI -- the menu-bar app and a human at a shell both call it.
image_status() {
  _mi="$MACHDIR/$MACHINE/boot2docker.iso"
  [ -f "$_mi" ] && [ -f "$ISO" ] || { echo absent; return; }
  if [ "$(shasum -a 256 "$_mi" 2>/dev/null | awk '{print $1}')" = "$(shasum -a 256 "$ISO" 2>/dev/null | awk '{print $1}')" ]; then
    echo current
  else
    echo stale
  fi
}

# Point the VM's Boot2DockerURL at the installed ISO. A Wowfunhappy-migrated host still holds the old
# DMG path (/Volumes/Docker for Mavericks/...), gone after unmount, so `docker-machine upgrade` fails
# fetching it. Unconditional and idempotent -- a no-op for a host already on the installed image.
repoint_iso_url() {
  _cfg="$MACHDIR/$MACHINE/config.json"
  [ -f "$_cfg" ] && sed -i '' "s|\"Boot2DockerURL\": *\"[^\"]*\"|\"Boot2DockerURL\": \"$ISO\"|" "$_cfg" 2>/dev/null || true
}
