# Jellyfin Docker NAS Stack

A Linux-first, self-hosted media server stack built around Jellyfin and Docker.

It includes:
- Streaming: Jellyfin
- Requests: Seerr
- Library automation: Sonarr, Radarr, Prowlarr, Bazarr
- Dashboard: Homarr with public family and private administrator boards
- Downloader behind VPN: qBittorrent + Gluetun
- Anti-bot helper: FlareSolverr
- Local entrypoint: nginx reverse proxy. Seerr is direct on its own port.

## Goals

- Easy to set up for first-time self-hosters
- Easy to run and maintain long-term
- Clear defaults with predictable behavior
- Reliable local LAN deployment
- Intel TerraMaster NAS readiness without risky host driver changes

## Quick Start

1. Install prerequisites
- Linux host with Docker Engine and Docker Compose (`docker compose` or `docker-compose`)
- Mullvad WireGuard details
- A path with enough storage for your media
- If Docker is not on `PATH`, set `DOCKER_BIN` and/or `DOCKER_COMPOSE_BIN` before running the helper scripts.

2. Run interactive setup
```bash
./scripts/setup.sh
```
This generates `.env`, creates only missing data and configuration folders, creates the restricted Gluetun telemetry policy, and validates your Compose config.

3. Start the stack
```bash
docker compose up -d
```

4. Open the services
- `http://<host>:<NGINX_PORT>/` (Homarr)
- `http://<host>:<NGINX_PORT>/jellyfin/`
- `http://<host>:5055/` (Seerr, unless you changed its port in `.env`)
- `http://<host>:<NGINX_PORT>/sonarr/`
- `http://<host>:<NGINX_PORT>/radarr/`
- `http://<host>:<NGINX_PORT>/prowlarr/`
- `http://<host>:<NGINX_PORT>/bazarr/`
- `http://<host>:<NGINX_PORT>/qbittorrent/`

5. Complete first-run app wiring
Follow [`docs/first-run.md`](docs/first-run.md).

## Configuration

Copy and edit `.env.example` manually if you do not use setup script:
```bash
cp .env.example .env
```

Required values:
- `COMMON_PATH`
- `TZ`, `PUID`, `PGID`
- `WIREGUARD_ADDRESSES`
- `WIREGUARD_PRIVATE_KEY`
- `WIREGUARD_PUBLIC_KEY`
- `WIREGUARD_ENDPOINT`
- `WIREGUARD_ALLOWED_IPS`
- `HOMARR_SECRET_ENCRYPTION_KEY` (setup generates a 64-character hexadecimal key)
- `GLUETUN_CONTROL_API_KEY` (setup generates this)

Optional values:
- `BIND_IP` defaults to `0.0.0.0`. Use `127.0.0.1` for localhost-only testing.
- `NGINX_PORT` (default `8090`)
- Seerr port, which defaults to `5055`
- `JELLYFIN_RENDER_GID` defaults to `109`. Setup tries to detect the host `render` group.
- `LOG_MAX_SIZE` / `LOG_MAX_FILE` (Docker JSON log rotation defaults)
- `HOMARR_BASE_URL` (the browser-facing nginx URL)
- Browser-facing Seerr URL for the Homarr application card
- `SERVER_COUNTRIES` (default `Sweden`)

## Common Commands

Start:
```bash
docker compose up -d
```

Stop:
```bash
docker compose down
```

Logs:
```bash
docker compose logs -f
```

Preflight checks:
```bash
./scripts/doctor.sh
./scripts/security-check.sh
```

CI checks:
```bash
./scripts/ci.sh
```

Optional env-file repair if you need the scripts to normalize `.env` line endings or tighten permissions:
```bash
./scripts/doctor.sh --fix-env
./scripts/security-check.sh --fix-env
```

Back up app configs only:
```bash
./scripts/backup-configs.sh
```

Validate a backup before restoring it:
```bash
./scripts/restore-configs.sh --archive /path/to/media-stack-configs-TIMESTAMP.tar.gz --dry-run
```

## Documentation

- Setup details: [`docs/setup.md`](docs/setup.md)
- First-run wiring: [`docs/first-run.md`](docs/first-run.md)
- Homarr board recipe: [`docs/homarr.md`](docs/homarr.md)
- Operations: [`docs/operations.md`](docs/operations.md)
- Updating and rollback: [`docs/updating.md`](docs/updating.md)
- Troubleshooting: [`docs/troubleshooting.md`](docs/troubleshooting.md)

## Repository Layout

- `docker-compose.yml`: stack definition
- `.env.example`: config template
- `homepage/`: legacy Homepage templates kept only for rollback compatibility
- `scripts/setup.sh`: interactive setup + env generation
- `scripts/sync-homepage-config.sh`: legacy rollback helper that normal setup does not use
- `scripts/doctor.sh`: read-only environment and compose validation by default (`--fix-env` is opt-in)
- `scripts/security-check.sh`: read-only VPN and local routing verification by default (`--fix-env` is opt-in)
- `scripts/backup-configs.sh`: config-only backup archives under `${COMMON_PATH}/Backups`
- `scripts/restore-configs.sh`: allowlisted config restore with dry-run and overwrite protection
- `nginx/conf.d/default.conf`: reverse proxy routes
- `docs/`: onboarding, operations, and troubleshooting

## Notes

- This project is HTTP-only for local self-hosting.
- qBittorrent is intentionally routed through Gluetun VPN.
- qBittorrent's WebUI password should be changed during first-run setup and should not be exposed publicly.
- Jellyfin is prepared for Intel Quick Sync and VA-API by mounting `/dev/dri` and adding `JELLYFIN_RENDER_GID`. Verify the device exists on TerraMaster before enabling hardware acceleration in Jellyfin.
- Core services now include healthchecks to make restarts and cold starts more predictable.
- Docker JSON logs are rotated by default to reduce slow NAS disk growth.
- Homarr never receives the Docker socket directly. Container statistics pass through an internal read-only proxy with write methods disabled.
- Homarr, Glances, the Docker socket proxy, and Gluetun telemetry are internal. nginx is the only Homarr entrypoint.
- nginx is intended for LAN use. Keep `BIND_IP` and `NGINX_PORT` behind your router or NAS firewall and do not forward it publicly.
- Seerr stays direct on its configured port. Do not forward that port publicly.
- If Docker is not on `PATH`, run manual compose commands with your host's `docker-compose` binary or export `DOCKER_COMPOSE_BIN`.
- Use only legally obtained media.
