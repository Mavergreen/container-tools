# Container Tools for Mavericks (standalone)

Docker on Mac OS X 10.9 Mavericks: `docker`, `docker compose`, `docker-machine`, `lazydocker` and `docked`, plus the `boot2docker.iso` the Docker VM boots. Unpack it anywhere. Nothing is installed, nothing runs at login, and nothing updates itself.

For the managed version, which sets up the VM, starts it at login, shows its state in the menu bar and keeps itself up to date, install the `.pkg` from the same release instead.

## Setup

You need VMware Fusion 8.5 (Docker runs in a small Linux VM). From the unpacked folder (`container-tools-<version>/`):

1. Put the tools on your `PATH`, for example in `~/.bash_profile`:

   ```sh
   export PATH="/path/to/container-tools-<version>/bin:$PATH"
   ```

2. Create the Docker VM once:

   ```sh
   docker-machine create -d vmwarefusion \
     --vmwarefusion-boot2docker-url "$PWD/share/boot2docker.iso" container-tools
   ```

3. Point `docker` at it, in each new shell (or in `~/.bash_profile`):

   ```sh
   eval "$(docker-machine env container-tools)"
   ```

Then `docker run --rm hello-world` should work.

After a restart, bring the VM back with `docker-machine start container-tools`. If its IP address changed, run `docker-machine regenerate-certs container-tools`.

## `docked`

`docked IMAGE [COMMAND...]` runs one command in a throwaway container on the files in the current folder. It's shorthand for `docker run --rm -it --network host -v "$PWD":/work -w /work IMAGE [COMMAND...]`. The VM can see only folders under `/Users`.
