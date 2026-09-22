A packaged, self-updating **Docker toolchain for OS X 10.9 (Mavericks)** — a signed `.pkg`, meant as a
drop-in successor to the hand-built "Container Tools for Mavericks" DMG, with newer components and an updater.

Versioned by date because this is a *distribution* of independently-versioned components rather than a
single upstream.

## What's new

- **Migration from Wowfunhappy's "Docker for Mavericks"** (or any prior `default` VM), done automatically
  the first time Container Tools reconciles:
  - **Carries your existing VM**: a stopped `default` docker-machine VM is renamed in place to
    `container-tools` (data disk preserved; a `default` compat symlink + `config.json.premigrate` backup
    are left behind). A *running* `default` is left untouched with a one-line "stop it to migrate" nudge.
  - **Neutralizes the old shell wiring, reversibly**: a leftover `eval "$(docker-machine env default)"`
    line in your `~/.bash_profile`/`~/.profile`/`~/.zshrc`/`~/.bashrc` is commented out with a marker and
    a one-time `.premigrate` backup — Container Tools points the docker CLI at the VM via a `mavericks`
    docker context instead.

## Components in this build

- **docker** CLI — docker/cli v29.6.2
- **docker compose** — v5.3.1 (CLI plugin + standalone `docker-compose`)
- **docker-machine** — v0.16.2
- **lazydocker** — v0.25.2, a terminal UI for Docker
- **boot2docker.iso** — dragonflylee v23.0.6
- **docked** — one-off-container convenience wrapper (after Wowfunhappy's DMG)
- A background **Sparkle auto-updater** (daily check)

All binaries are cross-built for x86_64 / min-10.9 with the patched mavericks Go toolchain and are
**self-contained** — legacy-support is linked in statically, so there is no dylib to install.

## Requires

OS X 10.9.5 or later, plus **VMware Fusion** to run the Docker daemon. After installing, see
<https://github.com/Mavergreen/container-tools> for the one-line `docker-machine create` setup.
