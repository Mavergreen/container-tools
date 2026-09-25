#!/bin/sh
# platform: host-agnostic
# Behavioral test of container-tools-get-fusion: parse the page, pick the FIRST dmg + a token-free
# mirror, download it, and fall back to opening the page on failure.
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
  export GET_FUSION_DEST="$WORK/Downloads"
  export GET_FUSION_PAGE_URL="https://example.invalid/fusion"
  cat > "$BIN/curl" <<EOF
#!/bin/sh
o=""; u=""
while [ \$# -gt 0 ]; do case "\$1" in -o) o="\$2"; shift 2;; -*) shift;; *) u="\$1"; shift;; esac; done
if [ -n "\$o" ]; then
  printf 'download %s\n' "\$u" >> "$CURL_LOG"
  [ -n "\${FAIL_DOWNLOAD:-}" ] && exit 22
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
EOF
  chmod +x "$BIN/curl" "$BIN/open"
  OLDPATH=$PATH; PATH="$BIN:$PATH"; export PATH
}
teardown() { [ -n "${OLDPATH:-}" ] && PATH=$OLDPATH; rm -rf "${WORK:-}"; }
trap teardown EXIT

setup
sh "$HELPER" || fail "helper exited non-zero on the happy path"
[ -f "$GET_FUSION_DEST/VMWare_Fusion_8.5.10.dmg" ] || fail "did not download the first dmg to DEST"
dl=$(grep '^download ' "$CURL_LOG" | head -1)
case "$dl" in
  *old.mac.gdn*|*gardenmirror.oldapplestuff.com*) : ;;
  *) fail "did not prefer a token-free mirror (got: $dl)" ;;
esac
case "$dl" in *"?"*) fail "picked a signed/expiring URL: $dl" ;; esac
case "$dl" in *Unlocker*) fail "picked the Unlocker, not Fusion: $dl" ;; esac
teardown

setup
FAIL_DOWNLOAD=1 sh "$HELPER" && fail "helper should exit non-zero when download fails"
grep -q "$GET_FUSION_PAGE_URL" "$OPEN_LOG" || fail "did not open the page on download failure"
teardown

setup
FAIL_PAGE=1 sh "$HELPER" && fail "helper should exit non-zero when the page fetch fails"
grep -q "$GET_FUSION_PAGE_URL" "$OPEN_LOG" || fail "did not open the page on page-fetch failure"
teardown

echo "get_fusion_test: OK"
