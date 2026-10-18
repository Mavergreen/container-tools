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
- `docked`

## Coming from Mavericks Forever

If you're using Wowfunhappy's Docker for Mavericks (from which this repo is derived), Container Tools handles the update for you:

- Your `default` VM gets renamed to `container-tools` with its data intact (if it's running, a notification asks you to `docker-machine stop default` first)
- Your shell profile's `eval "$(docker-machine env ...)"` lines get commented out (with a backup as `<profile>.premigrate`)

## Troubleshooting

- Logs: `~/Library/Logs/Mavergreen/container-tools/bootstrap.log`
- CPU and RAM: Adjust "container-tools" VM settings in VMware Fusion
