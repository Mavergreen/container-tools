#!/bin/sh
# platform: host-agnostic
# Stub-based test of the rename surgery. NEVER touches the real ~/.docker.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MIG="$ROOT/payload/docker-machine-migrate"
[ -f "$MIG" ] || { echo "docker_migrate_test: helper missing" >&2; exit 1; }
fail() { echo "docker_migrate_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/container-tools-migrate.XXXXXX")
  BIN="$WORK/bin"; mkdir -p "$BIN"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  export MAVERICKS_DOCKER_STATE_DIR="$WORK/state"
  export MAVERICKS_DOCKER_COMMON="$ROOT/payload/docker-machine-common.sh"
  export MAVERICKS_DOCKER_MACHDIR="$WORK/machines"
  OLDPATH=$PATH; PATH="$BIN:$PATH"
  # docker-machine stub: status default -> Stopped.
  cat > "$BIN/docker-machine" <<'EOF'
#!/bin/sh
[ "$1" = status ] && echo Stopped
exit 0
EOF
  chmod +x "$BIN/docker-machine"
  # A fake legacy machine.
  d="$MAVERICKS_DOCKER_MACHDIR/default"; mkdir -p "$d"
  cat > "$d/config.json" <<EOF
{ "Name": "default",
  "MachineName": "default",
  "Boot2DockerURL": "/Volumes/Docker for Mavericks/boot2docker.iso",
  "StorePath": "$MAVERICKS_DOCKER_MACHDIR/default",
  "VMXPath": "$MAVERICKS_DOCKER_MACHDIR/default/default.vmx" }
EOF
  printf 'displayName = "default"\nscsi0:0.fileName = "default.vmdk"\nnvram = "default.nvram"\n' > "$d/default.vmx"
  : > "$d/default.vmdk"; : > "$d/default.nvram"; : > "$d/ca.pem"; : > "$d/boot2docker.iso"
}
teardown() { PATH=$OLDPATH; rm -rf "$WORK"; }

case_migrate() {
  setup
  sh "$MIG" || fail "migrate should exit 0"
  nd="$MAVERICKS_DOCKER_MACHDIR/container-tools"
  [ -d "$nd" ] || fail "new machine dir must exist"
  [ -f "$nd/container-tools.vmx" ] || fail "vmx renamed"
  [ -f "$nd/container-tools.vmdk" ] || fail "vmdk (data disk) renamed"
  [ -f "$nd/ca.pem" ] || fail "certs preserved"
  grep -q '"MachineName": "container-tools"' "$nd/config.json" || fail "config MachineName rewritten"
  grep -q '"Name": "container-tools"' "$nd/config.json" || fail "config top-level Name rewritten"
  grep -q "machines/container-tools" "$nd/config.json" || fail "config StorePath rewritten"
  grep -q '/default\.vmx' "$nd/config.json" && fail "config still references default.vmx"
  grep -q '"Boot2DockerURL": "/usr/local/mavergreen/container-tools/share/boot2docker.iso"' "$nd/config.json" \
    || fail "config Boot2DockerURL must be repointed at the installed ISO (or upgrade re-fetches the old DMG)"
  grep -q '/Volumes/Docker for Mavericks' "$nd/config.json" && fail "config still points Boot2DockerURL at the old Wowfunhappy DMG"
  grep -q 'displayName = "container-tools"' "$nd/container-tools.vmx" || fail "vmx displayName rewritten"
  grep -q 'scsi0:0.fileName = "container-tools.vmdk"' "$nd/container-tools.vmx" || fail "vmx disk ref rewritten"
  [ -L "$MAVERICKS_DOCKER_MACHDIR/default" ] || fail "compat symlink left behind"
  [ -f "$nd/config.json.premigrate" ] || fail "config backup written"
  teardown
}

case_refuses_running() {
  setup
  cat > "$BIN/docker-machine" <<'EOF'
#!/bin/sh
[ "$1" = status ] && echo Running
exit 0
EOF
  chmod +x "$BIN/docker-machine"
  sh "$MIG" && fail "migrate must refuse while the VM is running"
  [ -d "$MAVERICKS_DOCKER_MACHDIR/default" ] || fail "must not have moved anything"
  teardown
}

case_migrate
case_refuses_running
echo "docker_migrate_test: OK"
