#!/bin/sh
# platform: host-agnostic
set -eu
cd "$(dirname "$0")/.."
if grep -l '/usr/local/mavericks-go' CMakeLists.txt .github/workflows/release.yml; then
  echo "FAIL: old golang prefix still referenced (files above)"
  exit 1
fi
grep -q '/usr/local/mavergreen/go126/bin/go' CMakeLists.txt || { echo "FAIL: native candidate path not updated"; exit 1; }
# install@v1 products: installs go126-cross at its Mac prefix, Linux too, so release.yml names it.
grep -q 'products: go126-cross@' .github/workflows/release.yml || { echo "FAIL: release.yml must install the cross toolchain through install@v1 products: go126-cross@<pin>"; exit 1; }
echo "docker prefix-check OK"
