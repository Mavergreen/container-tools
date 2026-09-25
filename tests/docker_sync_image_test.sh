#!/bin/sh
# platform: host-agnostic
# Stub-based test of container-tools-sync-image (the updater's post-install helper). NEVER touches the
# real ~/.docker. Under test: on a stale VM it (1) repoints a Wowfunhappy-migrated host's Boot2DockerURL
# at the installed ISO so a later `docker-machine upgrade` can fetch it, and (2) posts a NON-modal
# notification pointing at the menu / CLI. It must NOT pop a modal dialog or run the upgrade itself —
# the post-install relaunched updater's GUI session is unreliable (the dialog silently failed to appear
# after some updates); the roll happens via the menu-bar app or `docker-machine-ctl image-upgrade`.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SYNC="$ROOT/payload/container-tools-sync-image"
[ -f "$SYNC" ] || { echo "docker_sync_image_test: helper missing" >&2; exit 1; }
fail() { echo "docker_sync_image_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-sync.XXXXXX")
  BIN="$WORK/bin"; mkdir -p "$BIN"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export MAVERICKS_DOCKER_COMMON="$ROOT/payload/docker-machine-common.sh"
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state"
  export MAVERICKS_DOCKER_LOG="$WORK/log"
  export MAVERICKS_DOCKER_ISO="$WORK/installed.iso"; printf 'NEW-IMAGE\n' > "$MAVERICKS_DOCKER_ISO"
  export DM_LOG="$WORK/dm.args";  : > "$DM_LOG"
  export OSA_LOG="$WORK/osa.args"; : > "$OSA_LOG"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$DM_LOG"  > "$BIN/docker-machine";  chmod +x "$BIN/docker-machine"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$OSA_LOG" > "$BIN/osascript";      chmod +x "$BIN/osascript"
  OLDPATH=$PATH; PATH="$BIN:$PATH"
  # A stale, Wowfunhappy-migrated host: iso differs from installed, Boot2DockerURL = the old DMG.
  H="$MAVERICKS_DOCKER_MACHDIR/container-tools"; mkdir -p "$H"
  printf 'OLD-IMAGE\n' > "$H/boot2docker.iso"
  cat > "$H/config.json" <<EOF
{ "Name": "container-tools",
  "Boot2DockerURL": "/Volumes/Docker for Mavericks/boot2docker.iso" }
EOF
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }

case_stale_repoints_and_notifies() {
  setup
  sh "$SYNC" || fail "sync-image should exit 0"
  H="$MAVERICKS_DOCKER_MACHDIR/container-tools"
  grep -q "\"Boot2DockerURL\": \"$MAVERICKS_DOCKER_ISO\"" "$H/config.json" \
    || fail "must repoint Boot2DockerURL at the installed ISO"
  grep -q '/Volumes/Docker for Mavericks' "$H/config.json" \
    && fail "must not leave the stale Wowfunhappy DMG URL"
  grep -q 'display notification' "$OSA_LOG" \
    || fail "must post a (non-modal) notification about the available image"
  grep -q 'display dialog' "$OSA_LOG" \
    && fail "must NOT pop a modal dialog (post-install GUI session is unreliable)"
  grep -q 'upgrade' "$DM_LOG" \
    && fail "must NOT run docker-machine upgrade itself — the roll is user-triggered (menu / CLI)"
  teardown
}

# A host already on the current image: no repoint, no notification.
case_uptodate_noop() {
  setup
  H="$MAVERICKS_DOCKER_MACHDIR/container-tools"
  cp "$MAVERICKS_DOCKER_ISO" "$H/boot2docker.iso"   # same image => not stale
  sh "$SYNC" || fail "sync-image should exit 0 when nothing is stale"
  grep -q '/Volumes/Docker for Mavericks' "$H/config.json" \
    || fail "an up-to-date host must be left untouched"
  grep -q 'display notification' "$OSA_LOG" \
    && fail "an up-to-date host must not notify"
  teardown
}

case_stale_repoints_and_notifies
case_uptodate_noop
echo "docker_sync_image_test: OK"
