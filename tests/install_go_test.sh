#!/bin/sh
# platform: host-agnostic
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/cmake/install_go.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/ct-install-go.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
VER=1.26.9-mavericks.1

printf '%s  build-info-cross.txt\n%s  golang-1.26.9-cross-mavericks.1.pkg\n%s  golang-1.26.9-native-mavericks.1.pkg\n' \
  "$A" "$B" "$C" > "$T/golang"
printf '%s  go126-1.26.4-cross-mavericks.3.pkg\n%s  go126-1.26.4-native-mavericks.3.pkg\n' "$B" "$C" > "$T/go126"
printf '%s  go126-1.26.5-cross-mavericks.1.pkg\n%s  golang-1.26.5-cross-mavericks.1.pkg\n' "$A" "$B" > "$T/both"
printf '%s  golang-1.26.9-native-mavericks.1.pkg\n%s  golang-1.26.8-cross-mavericks.1.pkg\n%s  golang-1.26.9-cross-mavericks.10.pkg\n' \
  "$A" "$B" "$C" > "$T/none"

printf 'arch=arm64\ngo_line=126\nprefix=/usr/local/mavergreen/go126-cross\nvariant=cross\n' > "$T/info-current"
printf 'prefix=/usr/local/mavergreen/go126-cross-next\nvariant=cross\n' > "$T/info-moved"
printf 'prefix=/usr/local/go126-cross\n' > "$T/info-old-layout"
printf 'prefix=/usr/local/mavergreen/go126/cross\n' > "$T/info-nested"
printf 'arch=arm64\nvariant=cross\n' > "$T/info-none"

selects() {
  sums=$1; ver=$2; want=$3
  got="$(sh "$SCRIPT" --select "$T/$sums" "$ver")" \
    || { echo "--select $sums $ver failed" >&2; return 1; }
  [ "$got" = "$want" ] || { echo "--select $sums $ver printed '$got', want '$want'" >&2; return 1; }
}

selects_golang_prefix() { selects golang "$VER" "$B  golang-1.26.9-cross-mavericks.1.pkg"; }
selects_go126_prefix() { selects go126 1.26.4-mavericks.3 "$B  go126-1.26.4-cross-mavericks.3.pkg"; }
prefers_golang_prefix() { selects both 1.26.5-mavericks.1 "$B  golang-1.26.5-cross-mavericks.1.pkg"; }

missing_pkg_exits_1() {
  rc=0
  sh "$SCRIPT" --select "$T/none" "$VER" >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" -eq 1 ] || { echo "a SUMS without the cross pkg exited $rc, want 1" >&2; return 1; }
  [ ! -s "$T/out" ] || { echo "a SUMS without the cross pkg printed '$(cat "$T/out")'" >&2; return 1; }
  grep -q "$VER" "$T/err" || { echo "the refusal does not name the version: $(cat "$T/err")" >&2; return 1; }
}

prefix_is() {
  got="$(sh "$SCRIPT" --prefix "$T/$1")" || { echo "--prefix $1 failed" >&2; return 1; }
  [ "$got" = "$2" ] || { echo "--prefix $1 printed '$got', want '$2'" >&2; return 1; }
}
reads_current_prefix() { prefix_is info-current /usr/local/mavergreen/go126-cross; }
follows_a_moved_prefix() { prefix_is info-moved /usr/local/mavergreen/go126-cross-next; }

refuses_prefix() {
  rc=0
  sh "$SCRIPT" --prefix "$T/$1" >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" -eq 1 ] || { echo "--prefix $1 exited $rc, want 1 (a prefix outside /usr/local/mavergreen/<short> cannot be placed)" >&2; return 1; }
  [ ! -s "$T/out" ] || { echo "--prefix $1 printed '$(cat "$T/out")'" >&2; return 1; }
}
refuses_old_layout() { refuses_prefix info-old-layout; }
refuses_nested_prefix() { refuses_prefix info-nested; }
refuses_missing_prefix() { refuses_prefix info-none; }

bad_usage_exits_2() {
  for args in "--select" "--select $T/golang" "--select $T/golang 1.26.9" "--prefix" "--prefix a b" "" "a b"; do
    rc=0
    # shellcheck disable=SC2086
    sh "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || { echo "install_go.sh $args exited $rc, want 2" >&2; return 1; }
  done
}

# spec: install_go.sh's usage -- the install path fetches SHA256SUMS, picks the pkg with --select,
#       verifies build-info-cross.txt against it, reads the prefix there, and hands the pkg to
#       fetch_product_pkg.sh at that prefix; every stub refuses anything else, so nothing here reaches
#       the host's sudo or the network
installs_at_the_release_prefix() {
  info=$1; short=$2
  S="$T/shipyard-$short"; B="$T/stubs-$short"; R="$T/root-$short"
  mkdir -p "$S" "$B" "$R"
  rm -f "$T/fetch.args"
  base=https://github.com/Mavergreen/golang-126/releases/download/$VER
  cat > "$S/fetch_product_pkg.sh" <<EOS
printf '%s\n' "\$*" > "$T/fetch.args"
mkdir -p "\$5/bin"
printf '#!/bin/sh\necho go version stub\n' > "\$5/bin/go"
chmod +x "\$5/bin/go"
echo "\$5"
EOS
  cat > "$S/mavericks_fetch.sh" <<EOS
shipyard_curl() {
  [ "\$#" -eq 2 ] && [ "\$1" = $base/SHA256SUMS ] || { echo "stub shipyard_curl refuses: \$*" >&2; return 22; }
  cp "$T/golang" "\$2"
}
shipyard_fetch_verified() {
  [ "\$1 \$2 \$4" = "$base/build-info-cross.txt $A build-info-cross.txt" ] \
    || { echo "stub shipyard_fetch_verified refuses: \$*" >&2; return 1; }
  cp "$T/$info" "\$3/\$4"
}
EOS
  cat > "$B/curl" <<EOS
#!/bin/sh
echo "stub curl refuses: \$*" >&2
exit 99
EOS
  cat > "$B/sudo" <<EOS
#!/bin/sh
case "\$1 \$2" in
  "env MAVERGREEN_PKG_CACHE="*/install-go.*/cache)
    [ "\$3" = sh ] && [ "\$4" = "$S/fetch_product_pkg.sh" ] || { echo "stub sudo refuses: \$*" >&2; exit 99; }
    shift 3
    exec sh "\$@" ;;
  "rm -rf")
    case "\$3" in */install-go.*/cache) exit 0 ;; esac ;;
esac
echo "stub sudo refuses: \$*" >&2
exit 99
EOS
  chmod +x "$B/curl" "$B/sudo"
  out="$(PATH="$B:/usr/bin:/bin" SHIPYARD_SCRIPTS="$S" INSTALL_GO_ROOT="$R" \
    sh "$SCRIPT" "$VER" 2>"$T/install.err")" \
    || { echo "install_go.sh failed: $(cat "$T/install.err")" >&2; return 1; }
  [ "$out" = "$R/$short/bin" ] || { echo "install_go.sh printed '$out', want $R/$short/bin" >&2; return 1; }
  want="--asset golang-1.26.9-cross-mavericks.1.pkg $short $VER $R/$short"
  [ "$(cat "$T/fetch.args")" = "$want" ] \
    || { echo "fetch_product_pkg.sh got '$(cat "$T/fetch.args")', want '$want'" >&2; return 1; }
  if grep -q 'refuses' "$T/install.err"; then
    echo "a stub refused a call: $(cat "$T/install.err")" >&2; return 1
  fi
}
installs_at_current_prefix() { installs_at_the_release_prefix info-current go126-cross; }
installs_at_moved_prefix() { installs_at_the_release_prefix info-moved go126-cross-next; }

expect() {
  if "$1" 2>"$T/err1"; then echo "ok: $1"; else echo "FAIL: $1: $(cat "$T/err1")" >&2; fail=1; fi
}

expect selects_golang_prefix
expect selects_go126_prefix
expect prefers_golang_prefix
expect missing_pkg_exits_1
expect reads_current_prefix
expect follows_a_moved_prefix
expect refuses_old_layout
expect refuses_nested_prefix
expect refuses_missing_prefix
expect bad_usage_exits_2
expect installs_at_current_prefix
expect installs_at_moved_prefix
exit "$fail"
