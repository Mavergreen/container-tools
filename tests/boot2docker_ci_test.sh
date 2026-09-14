#!/bin/sh
# boot2docker.yml exists, runs on ubuntu, drives the iso preset + ctest. When a YAML
# parser is available it must also parse cleanly; otherwise the grep checks are the gate.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W="$ROOT/.github/workflows/boot2docker.yml"
[ -f "$W" ] || { echo "missing $W" >&2; exit 1; }
# Strict parse when PyYAML is present -- a real parse error must FAIL, not be masked.
# Fall back to the grep checks below only when no parser exists (don't false-fail hosts
# lacking PyYAML).
if python3 -c "import yaml" 2>/dev/null; then
  python3 -c "import yaml; yaml.safe_load(open('$W'))" \
    || { echo "boot2docker.yml is not valid YAML" >&2; exit 1; }
else
  echo "boot2docker_ci_test: no PyYAML; relying on structural grep checks" >&2
fi
grep -q 'runs-on: ubuntu-latest' "$W" || { echo "not ubuntu-latest" >&2; exit 1; }
# Anchored at command position, deliberately: a substring match for 'cmake --preset iso' is satisfied
# by 'shipyard-cmake --preset iso' too, so it can no longer fail -- and 'shipyard-cmake --preset iso'
# unanchored is satisfied by a comment while the run: line says plain cmake. Assert the line.
grep -qE '^[[:space:]]*shipyard-cmake --preset iso[[:space:]]*$' "$W" \
  || { echo "missing configure preset" >&2; exit 1; }
grep -qE '^[[:space:]]*shipyard-cmake --build --preset iso[[:space:]]*$' "$W" \
  || { echo "missing build preset" >&2; exit 1; }
grep -qE '^[[:space:]]*shipyard-ctest --preset iso([[:space:]]|$)' "$W" \
  || { echo "missing test preset" >&2; exit 1; }
# The other half of the same claim: nothing here may run a plain cmake/ctest/cpack. The positives
# above still pass if someone ADDS a plain one beside them; this is what catches that.
if grep -qE '^[[:space:]]*(cmake|ctest|cpack)([[:space:]]|$)' "$W"; then
  echo "boot2docker.yml runs a plain cmake/ctest/cpack (only shipyard-cmake configures against shipyard)" >&2
  exit 1
fi
echo "boot2docker_ci_test: OK"
