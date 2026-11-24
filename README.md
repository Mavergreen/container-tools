# Container Tools for Mavericks

Docker runtime and CLI tools for Mac OS X 10.9 Mavericks.

(Docker Desktop for Mac requires macOS 14 Sonoma or later.)

## How to use

1. If the Container Tools menu shows "Get VMware Fusion...", select it
2. Once the Fusion installer has been downloaded, install it
3. In the Container Tools menu, within a minute, you'll see "Docker: Starting..."
4. Wait for it to say "Docker: Running"

On reboot, the Docker VM and the Container Tools menu will start automatically.

## Included

- `docker`
- `docker compose`
- `docker-machine`
- `lazydocker`
- `docked`: `docked IMAGE [COMMAND...]` runs one command in a throwaway container on the files in the current folder. It's shorthand for `docker run --rm -it --network host -v "$PWD":/work -w /work IMAGE [COMMAND...]` (`-t` only at a terminal, so piping works), and it makes sure Docker is ready first. The Docker VM can see only folders under `/Users`; elsewhere, `docked` warns that `/work` will be empty.

## Coming from Mavericks Forever

If you're using Wowfunhappy's Docker for Mavericks (from which this repo is derived), Container Tools handles the update for you:

- Your `default` VM gets renamed to `container-tools` with its data intact (if it's running, a notification asks you to `docker-machine stop default` first)
- Your shell profile's `eval "$(docker-machine env ...)"` lines get commented out (with a backup as `<profile>.premigrate`)

## Resource sizing

The tested starting baseline for GUI workloads (Signal, 1Password, etc.) is **2 GiB RAM and two vCPUs**. The first time the Docker VM is created with fewer resources than this, Container Tools notifies you. 4 GiB and two vCPUs offer additional headroom for heavier or concurrent use.

There is no established host minimum: a lightly loaded Mac can run the VM below this baseline, but host RAM pressure, swap activity, and disk fill rate all affect performance. Watch Activity Monitor if things feel sluggish.

**To adjust resources:**

1. Close any Porthole apps and other running containers.
2. Stop the Docker VM: Container Tools menu → **Stop Docker** (or `docker-machine-ctl stop`).
3. In VMware Fusion, open the **container-tools** VM settings and change Memory and Processors. Raising VM RAM also grows the VM's `.vmem` file on disk; **Start Docker** will refuse if the Mac lacks sufficient free space.
4. Verify the change: `docker-machine-ctl resource-status` should report the new values (`source=vmx` confirms the VMX file is current).
5. Start the VM: Container Tools menu → **Start Docker**.

**Container shared memory:** Each Porthole app container is started with `--shm-size 512m`. This sets an upper bound on `/dev/shm`; it does not reserve RAM ahead of time. (256 MiB was tested as a reference value; there is no 64 MiB production default.) Changing the SHM limit for an existing container requires stopping and recreating it with its named volumes intact — an intentional step, not something that happens automatically. Moving a monitor between displays does not restart apps.

## Troubleshooting

- Logs: `~/Library/Logs/Mavergreen/container-tools/bootstrap.log`
- CPU and RAM: adjust "container-tools" VM settings in VMware Fusion (see Resource sizing above)
