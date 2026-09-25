#!/bin/sh
# platform: host-agnostic
# renovate.json (under .github/ since 777814d) is valid JSON and declares a
# customManager for components/*/version.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 -c "import json,sys; json.load(open('$ROOT/.github/renovate.json'))" \
  || { echo "renovate.json invalid JSON" >&2; exit 1; }
grep -q 'components/.*/version' "$ROOT/.github/renovate.json" \
  || { echo "renovate.json does not track component version files" >&2; exit 1; }
# boot2docker's BASE image must be Renovate-tracked (docker datasource, digest and all), or it rots in
# place until its Debian falls out of security support and apt-get update fails the iso build. Run the
# manager's own regex over the real pin file and check what it extracts.
python3 - "$ROOT/.github/renovate.json" "$ROOT/components/boot2docker/version" <<'EOF' \
  || { echo "renovate.json does not track boot2docker's BASE image" >&2; exit 1; }
import json, re, sys
cfg = json.load(open(sys.argv[1])); pin = open(sys.argv[2]).read()
path = "components/boot2docker/version"
for m in cfg.get("customManagers", []):
    if m.get("datasourceTemplate") != "docker":
        continue
    if not any(re.search(p.strip("/"), path) for p in m.get("managerFilePatterns", [])):
        continue
    for s in m.get("matchStrings", []):
        g = re.search(s.replace("(?<", "(?P<"), pin, re.M)
        if (g and g.groupdict().get("depName") == "debian"
                and re.fullmatch(r"\d+-slim", g.group("currentValue"))
                and re.fullmatch(r"sha256:[0-9a-f]{64}", g.group("currentDigest"))):
            sys.exit(0)
sys.exit(1)
EOF
# UPSTREAM_VERSION is the committed input the version derives from. VERSION is NOT checked here: it
# is a build product (gitignored), so requiring it would fail on a fresh clone -- and the committed
# copy this replaces is precisely what drifted to .2 while releases were at .14.
[ -s "$ROOT/UPSTREAM_VERSION" ] || { echo "UPSTREAM_VERSION missing/empty" >&2; exit 1; }
echo "renovate_test: OK"
