# Jellyfin Docker NAS Stack

A Linux-first, self-hosted media server stack built around Jellyfin and Docker.

It includes:
- Streaming: Jellyfin
- Requests: Jellyseerr
- Library automation: Sonarr, Radarr, Prowlarr, Bazarr
- Dashboard: Homepage
- Downloader behind VPN: qBittorrent + Gluetun
- Anti-bot helper: FlareSolverr
- Local entrypoint: nginx reverse proxy (Jellyseerr is direct on its own port)

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
This generates `.env`, creates only missing data folders (reusing existing ones), syncs the repo-managed Homepage config, and validates your Compose config.

3. Start the stack
```bash
docker compose up -d
```

4. Open the services
- `http://<host>:<NGINX_PORT>/jellyfin/`
- `http://<host>:<JELLYSEERR_PORT>/`
- `http://<host>:<NGINX_PORT>/sonarr/`
- `http://<host>:<NGINX_PORT>/radarr/`
- `http://<host>:<NGINX_PORT>/prowlarr/`
- `http://<host>:<NGINX_PORT>/bazarr/`
- `http://<host>:<NGINX_PORT>/qbittorrent/`
- `http://<host>:<NGINX_PORT>/homepage/`

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

Optional values:
- `BIND_IP` (default `0.0.0.0`; use `127.0.0.1` for localhost-only testing)
- `NGINX_PORT` (default `8090`)
- `JELLYSEERR_PORT` (default `5055`)
- `JELLYFIN_RENDER_GID` (default `109`; setup tries to detect the host `render` group)
- `LOG_MAX_SIZE` / `LOG_MAX_FILE` (Docker JSON log rotation defaults)
- `JELLYSEERR_EXTERNAL_URL` (used by Homepage for the Jellyseerr card; set this to your browser-facing LAN URL)
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

Resync Homepage config:
```bash
./scripts/sync-homepage-config.sh
```

Back up app configs only:
```bash
./scripts/backup-configs.sh
```

Preview Homepage sync changes first:
```bash
./scripts/sync-homepage-config.sh --dry-run
```

## Documentation

- Setup details: [`docs/setup.md`](docs/setup.md)
- First-run wiring: [`docs/first-run.md`](docs/first-run.md)
- Operations: [`docs/operations.md`](docs/operations.md)
- Updating and rollback: [`docs/updating.md`](docs/updating.md)
- Troubleshooting: [`docs/troubleshooting.md`](docs/troubleshooting.md)

## Repository Layout

- `docker-compose.yml`: stack definition
- `.env.example`: config template
- `homepage/`: repo-managed Homepage dashboard templates
- `scripts/setup.sh`: interactive setup + env generation
- `scripts/sync-homepage-config.sh`: sync Homepage templates into `${COMMON_PATH}/Homepage/Config`
- `scripts/doctor.sh`: read-only environment and compose validation by default (`--fix-env` is opt-in)
- `scripts/security-check.sh`: read-only VPN and local routing verification by default (`--fix-env` is opt-in)
- `scripts/backup-configs.sh`: config-only backup archives under `${COMMON_PATH}/Backups`
- `nginx/conf.d/default.conf`: reverse proxy routes
- `docs/`: onboarding, operations, and troubleshooting

## Notes

- This project is HTTP-only for local self-hosting.
- qBittorrent is intentionally routed through Gluetun VPN.
- qBittorrent's WebUI password should be changed during first-run setup and should not be exposed publicly.
- Jellyfin is prepared for Intel Quick Sync/VA-API by mounting `/dev/dri` and adding `JELLYFIN_RENDER_GID`; verify the device exists on TerraMaster before enabling hardware acceleration in Jellyfin.
- Core services now include healthchecks to make restarts and cold starts more predictable.
- Docker JSON logs are rotated by default to reduce slow NAS disk growth.
- Homepage mounts the Docker socket read-only so it can surface container-aware dashboard features; treat the Homepage container as more sensitive because of that access.
- nginx is intended for LAN use; keep `BIND_IP`/`NGINX_PORT` behind your router/NAS firewall and do not forward it publicly.
- Jellyseerr stays direct on `JELLYSEERR_PORT`; if you keep that port, do not forward it publicly.
- If Docker is not on `PATH`, run manual compose commands with your host's `docker-compose` binary or export `DOCKER_COMPOSE_BIN`.
- Use only legally obtained media.
