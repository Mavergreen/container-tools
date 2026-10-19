#!/bin/sh
# platform: host-agnostic
# Behavioral test of container-tools-get-fusion: parse the page, pick the FIRST dmg + a token-free
# mirror, hand that URL to the default browser (which downloads it with its own progress), and fall
# back to opening the page on failure.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/payload/container-tools-get-fusion"
FIXTURE="$ROOT/tests/fixtures/macintoshgarden-fusion.html"
fail() { echo "get_fusion_test: FAIL: $*" >&2; exit 1; }

setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/getfusion.XXXXXX")
  BIN="$WORK/bin"; mkdir -p "$BIN"
  export CURL_LOG="$WORK/curl.args"; : > "$CURL_LOG"
  export OPEN_LOG="$WORK/open.args"; : > "$OPEN_LOG"
  export GET_FUSION_PAGE_URL="https://example.invalid/fusion"
  cat > "$BIN/curl" <<EOF
#!/bin/sh
o=""; u=""
while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift 2;; -*) shift;; *) u="\$1"; shift;; esac; done
if [ -n "\$o" ]; then
  printf 'download %s\n' "\$u" >> "$CURL_LOG"
  echo fakedmg > "\$o"; exit 0
else
  printf 'page %s\n' "\$u" >> "$CURL_LOG"
  [ -n "\${FAIL_PAGE:-}" ] && exit 22
  cat "$FIXTURE"
fi
EOF
  cat > "$BIN/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$OPEN_LOG"
case "\$*" in *.dmg*) [ -n "\${FAIL_OPEN_DMG:-}" ] && exit 1 ;; esac
exit 0
EOF
  chmod +x "$BIN/curl" "$BIN/open"
  OLDPATH=$PATH; PATH="$BIN:$PATH"; export PATH
}
teardown() { [ -n "${OLDPATH:-}" ] && PATH=$OLDPATH; rm -rf "${WORK:-}"; }
trap teardown EXIT

setup
sh "$HELPER" || fail "helper exited non-zero on the happy path"
grep -q '^download ' "$CURL_LOG" && fail "the helper downloaded the dmg itself; the browser should, so the user sees its progress"
opened=$(head -1 "$OPEN_LOG")
case "$opened" in
  *VMWare_Fusion_8.5.10.dmg) : ;;
  *) fail "did not hand the first dmg to the browser (opened: $opened)" ;;
esac
case "$opened" in
  *old.mac.gdn*|*gardenmirror.oldapplestuff.com*) : ;;
  *) fail "did not prefer a token-free mirror (opened: $opened)" ;;
esac
case "$opened" in *"?"*) fail "opened a signed/expiring URL: $opened" ;; esac
case "$opened" in *Unlocker*) fail "opened the Unlocker, not Fusion: $opened" ;; esac
[ "$(wc -l < "$OPEN_LOG" | tr -d ' ')" = 1 ] || fail "the happy path should open exactly one URL: $(cat "$OPEN_LOG")"
teardown

setup
FAIL_OPEN_DMG=1 sh "$HELPER" && fail "helper should exit non-zero when the browser can't be handed the dmg"
grep -q "^$GET_FUSION_PAGE_URL\$" "$OPEN_LOG" || fail "did not open the page when opening the dmg failed"
teardown

setup
FAIL_PAGE=1 sh "$HELPER" && fail "helper should exit non-zero when the page fetch fails"
grep -q "$GET_FUSION_PAGE_URL" "$OPEN_LOG" || fail "did not open the page on page-fetch failure"
teardown

echo "get_fusion_test: OK"
