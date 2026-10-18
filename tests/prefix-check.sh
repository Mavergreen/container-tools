#!/bin/sh
# platform: host-agnostic
set -eu
cd "$(dirname "$0")/.."
if git ls-files CMakeLists.txt .github/workflows/release.yml | xargs grep -l '/usr/local/mavericks-go' 2>/dev/null | grep -q .; then
  echo "FAIL: old golang prefix still referenced:"; git ls-files CMakeLists.txt .github/workflows/release.yml | xargs grep -l '/usr/local/mavericks-go'
  exit 1
fi
grep -q '/usr/local/mavergreen/go126/bin/go' CMakeLists.txt || { echo "FAIL: native candidate path not updated"; exit 1; }
if grep -q '/usr/local/mavergreen/go126-cross' .github/workflows/release.yml; then
  echo "FAIL: release.yml hard-codes the cross toolchain's prefix; cmake/install_go.sh reads it from the release's build-info-cross.txt"; exit 1
fi
grep -q 'sh cmake/install_go.sh' .github/workflows/release.yml || { echo "FAIL: release.yml must install the cross toolchain through cmake/install_go.sh"; exit 1; }
echo "docker prefix-check OK"
