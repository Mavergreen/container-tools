#!/bin/sh
# platform: host-agnostic
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/ct-hook.XXXXXX")"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$W/stub" "$W/vol"
for c in launchctl open stat; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\necho 501\n' "$c" "$W" > "$W/stub/$c"; chmod +x "$W/stub/$c"; done
: > "$W/calls"
ROOT="$W/vol" PATH="$W/stub:$PATH" sh "$R/cmake/postinstall-hook.sh" || fail "the hook must succeed when installing to another volume"
[ ! -s "$W/calls" ] || fail "installing to another volume must not start the menu-bar app or the VM agent: $(cat "$W/calls")"
echo "PASS: postinstall_hook_test"
