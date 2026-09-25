# Container Tools for Mavericks

docker, docker compose, docker-machine, and lazydocker for OS X 10.9. The daemon
runs in a Linux VM (VMware Fusion 8); docker-machine manages it.

## Setup

Install VMware Fusion, then bring the Docker VM up once:

```sh
docker-machine-bootstrap
```

It creates the VM from the bundled image (first run only, ~1-2 min in a Terminal),
starts it, and points a `docker` **context** named `mavericks` at it — so `docker`,
`docker compose`, and `lazydocker` just work in any shell, with no environment
variables to set. `docked IMAGE CMD` runs a container with `$PWD` at `/work/`.

To start the VM automatically at login:

```sh
launchctl load -w /Library/LaunchAgents/dev.mavergreen.container-tools-machine.plist
```

## Updates

The package updates itself, and after each update offers to roll your VM onto the
new image — nothing to run by hand.

## Notes

- The commands install into `/usr/local/mavergreen/container-tools/bin`, on your PATH through
  `/usr/local/mavergreen/bin`. If Docker Desktop is also installed, its `/usr/local/bin/docker`
  comes first on PATH and shadows this one.
- If `docker` says "cannot connect," the VM is stopped — run `docker-machine-bootstrap`
  (or start it from the menu bar) and retry.
- Migrating from an older setup? Remove any `eval "$(docker-machine env …)"` or
  hardcoded `DOCKER_HOST=` line from your shell profile — it overrides the managed
  context. The bootstrap will notify you if it finds one.
- The VM appears in VMware Fusion as "container-tools"; adjust CPU/RAM in its Settings.
- Coming from Wowfunhappy's DMG or another setup with a `default` VM? Run `docker-machine-ctl migrate`
  once (with the VM stopped) to rename it to `container-tools`, preserving your data.
- boot2docker.iso: https://github.com/dragonflylee/boot2docker/
