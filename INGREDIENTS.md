# Build ingredients

Everything baked into the shipped `.pkg`, and how a change to it reaches a release. An *ingredient* is
an input to the product; the *own upstream* is the thing a repo exists to port.

**This repo is its own upstream.** It assembles several independent docker components around its own
code (`cmake/`, `menubar/`, `payload/`, the updater), so it versions itself by date, `YYYYMMDD.N`, with
no `-mavericks.N` axis. `UPSTREAM_VERSION` is the date this repo's own code last changed:

- A release carrying any change besides ingredient pins sets `UPSTREAM_VERSION` to that day (by hand,
  in the same change) and ships as `<date>.1`.
- An ingredient-only repackage keeps the date and ships as `<date>.(N+1)`. The repackage caller runs
  with `own-upstream-paths: ""`, so every pin under `components/` is an ingredient.

Releases through `20260727-mavericks.37` used the port scheme. Sparkle orders `20261018.1` after them.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| docker CLI | `components/docker-cli/version` (`REPO=` + `REF=` + `DIGEST=`) | ✅ `git-refs` + `currentDigest` | watched path → repackage dispatched → `<date>.(N+1)` |
| docker CLI patch overlay | `components/docker-cli/patches/*.patch` | n/a (this repo's own fix) | **is** an ingredient — it is applied into the built binary, so a change rebuilds it |
| docker Compose | `components/docker-compose/version` | ✅ `git-refs` + `currentDigest` | same |
| docker Machine | `components/docker-machine/version` | ✅ `git-refs` + `currentDigest` | same |
| lazydocker | `components/lazydocker/version` | ✅ `git-refs` + `currentDigest` | same |
| boot2docker source | `components/boot2docker/version` | ✅ `git-refs` + `currentDigest` | same; the iso build re-clones (commit-digest-verified) + rebuilds |
| boot2docker build base (Debian) | `components/boot2docker/version` (`BASE=debian:<N>-slim@sha256:…`) | ✅ `docker` + `currentDigest` (digest refreshes and the next Debian major) | same; replaces upstream's hard-coded `FROM` (`cmake/rebase_dockerfile.sh`), whose bullseye aged out of security support and broke `apt-get update` |
| boot2docker patch overlay | `components/boot2docker/patches/*.patch` | n/a (this repo's own fix) | **is** an ingredient — it is applied into the iso, so a change rebuilds it |
| Mavergreen Go cross toolchain | `components/golang/version` | ✅ `github-releases` on `Mavergreen/golang-126` | watched path → repackage rebuilt on the new Go |
| MacOSX10.9 SDK, Sparkle framework | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a *moving* tag: content changes without the pin changing, so nothing auto-repackages |

Not ingredients: `cmake/`, `menubar/`, `payload/`, and the updater are this repo's own code. A change
there moves `UPSTREAM_VERSION` to the day of the change, and you cut the release deliberately
(`workflow_dispatch` with `local_release=true`), which ships `<date>.1`.

## Why the patch counts as an ingredient

`cmake/build_boot2docker.sh` applies every `components/boot2docker/patches/*.patch` into the iso build,
and `cmake/build_docker_cli.sh` applies every `components/docker-cli/patches/*.patch` into the docker
CLI build (adding `/usr/local/mavergreen/container-tools/lib/docker/cli-plugins` to its plugin search
list), so either patch overlay changes the shipped product exactly as a version bump would. The caller
watches `components/**`, which covers both — and generated release notes describe a patch by its
subject line and line delta rather than a meaningless byte count.

## Acceptance is manual for the iso

CI proves the build and the fetch/fingerprint gates; a modern runner cannot boot-proof the iso, so the
boot-proof auto-skips (`ctest` code 77). Real-10.9 boot testing is the acceptance bar — do not read a
green CI as proof the iso boots.

## Acceptance on real 10.9

Every release is installed on a real 10.9.5 guest before it publishes: release.yml's `on-mavericks`
job (`Mavergreen/mavericks-vm`) installs the pkg the way a user does, runs `tests/smoke-mavericks.sh`
there, and runs the repo's tests under 10.9's own `/bin/sh` and tools. What the guest cannot run is
declared below as `on-target:` deviations and stays manual acceptance on a real Mac.

## Upstream release notes

No upstream release notes: there is no single upstream to link. The product bundles six components
(docker-cli, docker-compose, docker-machine, lazydocker, boot2docker, golang), each an ingredient
with its own pin; their changes are named in each release's generated "Build ingredients" section.

## Conformance deviations

- scheme: Container Tools is its own upstream (its own code around bundled ingredients, no single release of someone else's to repackage), so it versions itself by date as YYYYMMDD.N with no -mavericks.N axis
- unlinked:components/boot2docker/version:BASE: a Debian slim base-image refresh publishes no change notes
- on-target:docker-vm: VMware Fusion does not run nested in the QEMU guest, so the Docker VM itself, and everything that needs its daemon (docked, docker run, VM create/start/stop), is accepted by hand on a real Mac
- on-target:menubar-gui: the guest has no screen, so the menu bar app's and the updater's GUI are accepted by hand on a real Mac; the smoke checks only that both are installed
