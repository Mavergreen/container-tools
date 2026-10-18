#!/bin/sh
# platform: macOS-only -- shipyard's fetch_product_pkg.sh expands the toolchain pkg with pkgutil
#   usage: install_go.sh <version>
#          Puts the Go cross toolchain of Mavergreen golang-126 release <version>
#          (components/golang/version) where that release says it lives: the prefix= line of its
#          build-info-cross.txt, verified against the release's SHA256SUMS. shipyard's
#          fetch_product_pkg.sh fetches, verifies and extracts the pkg there. Prints the toolchain's
#          bin directory, and nothing else, on stdout. Needs $SHIPYARD_SCRIPTS and sudo.
#          INSTALL_GO_ROOT replaces /usr/local/mavergreen (the tests put the toolchain in a temp dir).
#          install_go.sh --select <SHA256SUMS> <version>
#          Prints the SHA256SUMS line of <version>'s cross pkg, named golang-... or go126-...;
#          exits 1 when there is none.
#          install_go.sh --prefix <build-info-cross.txt>
#          Prints the toolchain's prefix; exits 1 unless it is /usr/local/mavergreen/<short name>.
set -eu
REPO=golang-126
FAMILY_ROOT=/usr/local/mavergreen
ROOT_DIR="${INSTALL_GO_ROOT:-$FAMILY_ROOT}"

usage() {
  echo "usage: install_go.sh <version> | --select <SHA256SUMS> <version> | --prefix <build-info-cross.txt>" >&2
  exit 2
}

check_version() {
  case "$1" in
    *-mavericks.*) ;;
    *) echo "install_go: '$1' is not a <go version>-mavericks.<n> release" >&2; exit 2 ;;
  esac
}

# spec: mavergreen-conventions SKILL.md "Download the toolchain asset prefix-tolerantly" -- golang's
#       cross pkg was renamed go126- to golang- at 1.26.5-mavericks.1
select_pkg() {
  gover="${2%%-mavericks.*}"
  rev="${2#"$gover"-}"
  for pref in golang go126; do
    line="$(awk -v f="$pref-$gover-cross-$rev.pkg" '$2 == f' "$1")"
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done
  echo "install_go: $1 lists no cross pkg for $2 (neither golang-$gover-cross-$rev.pkg nor go126-$gover-cross-$rev.pkg)" >&2
  return 1
}

# spec: mavergreen-conventions SKILL.md "Install layout and identity" -- a product owns exactly
#       /usr/local/mavergreen/<short name>, and fetch_product_pkg.sh extracts that tree, so a prefix of
#       any other shape is one this script cannot place
prefix_of() {
  p="$(sed -n 's/^prefix=//p' "$1" | head -1)"
  short="${p#"$FAMILY_ROOT"/}"
  case "$short" in
    ''|*/*|*[!a-z0-9-]*)
      echo "install_go: $1 says prefix='$p', not $FAMILY_ROOT/<short name>" >&2
      return 1 ;;
  esac
  printf '%s\n' "$p"
}

case "${1:-}" in
  --select)
    [ "$#" -eq 3 ] || usage
    check_version "$3"
    [ -r "$2" ] || { echo "install_go: cannot read $2" >&2; exit 2; }
    select_pkg "$2" "$3"
    exit ;;
  --prefix)
    [ "$#" -eq 2 ] || usage
    [ -r "$2" ] || { echo "install_go: cannot read $2" >&2; exit 2; }
    prefix_of "$2"
    exit ;;
esac
[ "$#" -eq 1 ] || usage
ver="$1"
check_version "$ver"
: "${SHIPYARD_SCRIPTS:?install_go: SHIPYARD_SCRIPTS must name the shipyard scripts directory (install@v1 sets it)}"

base="https://github.com/Mavergreen/$REPO/releases/download/$ver"
d="$(mktemp -d "${TMPDIR:-/tmp}/install-go.XXXXXX")"
trap 'sudo rm -rf "$d/cache"; rm -rf "$d"' EXIT
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
shipyard_curl "$base/SHA256SUMS" "$d/SHA256SUMS"
line="$(select_pkg "$d/SHA256SUMS" "$ver")"
pkg="${line##* }"
info_sha="$(awk '$2 == "build-info-cross.txt" { print $1 }' "$d/SHA256SUMS")"
[ -n "$info_sha" ] || { echo "install_go: $base/SHA256SUMS does not list build-info-cross.txt" >&2; exit 1; }
shipyard_fetch_verified "$base/build-info-cross.txt" "$info_sha" "$d" build-info-cross.txt
prefix="$(prefix_of "$d/build-info-cross.txt")"
short="${prefix##*/}"
dest="$ROOT_DIR/$short"
# platform: the pkg's go.env names CC by its absolute path under its prefix, so the toolchain goes
#           where the pkg installs it; that directory's parent is root's
sudo env MAVERGREEN_PKG_CACHE="$d/cache" \
  sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "$pkg" "$short" "$ver" "$dest" >&2
GOTOOLCHAIN=local "$dest/bin/go" version >&2
printf '%s\n' "$dest/bin"
