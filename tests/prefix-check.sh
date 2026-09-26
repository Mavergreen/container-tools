#!/bin/sh
# platform: host-agnostic
set -eu
cd "$(dirname "$0")/.."
if git ls-files CMakeLists.txt .github/workflows/release.yml | xargs grep -l '/usr/local/mavericks-go' 2>/dev/null | grep -q .; then
  echo "FAIL: old golang prefix still referenced:"; git ls-files CMakeLists.txt .github/workflows/release.yml | xargs grep -l '/usr/local/mavericks-go'
  exit 1
fi
grep -q '/usr/local/mavergreen/go126/bin/go' CMakeLists.txt || { echo "FAIL: native candidate path not updated"; exit 1; }
grep -q '/usr/local/mavergreen/go126-cross/bin/go' .github/workflows/release.yml || { echo "FAIL: cross PATH assertion not updated"; exit 1; }
echo "docker prefix-check OK"
