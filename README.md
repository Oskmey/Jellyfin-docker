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
./scripts/stack.sh setup
```
This generates `.env`, creates only missing data and configuration folders, creates the restricted Gluetun telemetry policy, and validates your Compose config.

3. Start the stack
For an existing installation, follow [`docs/updating.md`](docs/updating.md) before starting with the revised Compose file.
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

To fill in settings manually, copy and edit `.env.example`, then run setup without prompts:
```bash
cp .env.example .env
# Edit .env before continuing.
./scripts/stack.sh setup --non-interactive --env-file .env
```
Setup creates the required folders, Gluetun/Glances files, and missing secrets; copying `.env` alone is insufficient.

Required values:
- `COMMON_PATH`
- `TZ`, `PUID`, `PGID`
- `WIREGUARD_ADDRESSES`
- `WIREGUARD_PRIVATE_KEY`
- `HOMARR_BASE_URL` (the browser-facing origin, for example `http://nas.local:8090`, without a path)
- `HOMARR_SECRET_ENCRYPTION_KEY` (setup generates a 64-character hexadecimal key)
- `GLUETUN_CONTROL_API_KEY` (setup generates this)

Optional values:
- `BIND_IP` defaults to `0.0.0.0`. Use `127.0.0.1` for localhost-only testing.
- `NGINX_PORT` (default `8090`)
- Seerr port, which defaults to `5055`
- `JELLYFIN_RENDER_GID` defaults to `109`. Setup first checks the render device's numeric group, then the host `render` group.
- `LOG_MAX_SIZE` / `LOG_MAX_FILE` (Docker JSON log rotation defaults)
- Browser-facing Seerr URL for the Homarr application card
- `SERVER_COUNTRIES` (default `Sweden`)
- `PROWLARR_MEM_LIMIT`, `BAZARR_MEM_LIMIT`, `FLARESOLVERR_MEM_LIMIT`, `HOMARR_MEM_LIMIT`, `GLANCES_MEM_LIMIT` (memory caps for non-critical services; see [`docs/operations.md`](docs/operations.md#memory-on-a-small-nas))
- `WIREGUARD_ALLOWED_IPS` (default `0.0.0.0/0` for the IPv4 tunnel)

## Common Commands

Start:
```bash
docker compose up -d --pull never
```
This uses locally available images. Follow the update guide before pulling new images; the initial setup command above can fetch missing images.

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
./scripts/stack.sh doctor
./scripts/stack.sh security-check
```

CI checks:
```bash
./scripts/ci.sh
```

Optional env-file repair if you need the scripts to normalize `.env` line endings or tighten permissions:
```bash
./scripts/stack.sh doctor --fix-env
./scripts/stack.sh security-check --fix-env
```

Back up app configs only:
```bash
./scripts/stack.sh backup
```

Validate a backup before restoring it:
```bash
./scripts/stack.sh restore --archive /path/to/media-stack-configs-TIMESTAMP.SUFFIX.tar.gz --dry-run
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
- `scripts/stack.sh`: single helper script; run `./scripts/stack.sh help` for its commands:
  - `setup`: interactive setup + env generation
  - `doctor`: read-only environment and compose validation by default (`--fix-env` is opt-in)
  - `security-check`: read-only VPN and local routing verification by default (`--fix-env` is opt-in)
  - `backup`: config-only backup archives under `${COMMON_PATH}/Backups` (`--keep N` prunes older archives)
  - `restore`: allowlisted config restore with dry-run and overwrite protection
- `scripts/ci.sh`: repository checks run by GitHub Actions
- `nginx/conf.d/default.conf`: reverse proxy routes
- `docs/`: onboarding, operations, and troubleshooting

## Notes

- This project is HTTP-only for local self-hosting.
- qBittorrent is intentionally routed through Gluetun VPN.
- qBittorrent's WebUI password should be changed during first-run setup and should not be exposed publicly.
- Jellyfin is prepared for Intel Quick Sync and VA-API by mounting `/dev/dri` and adding `JELLYFIN_RENDER_GID`. Verify the device exists on TerraMaster before enabling hardware acceleration in Jellyfin.
- Core services now include healthchecks to make restarts and cold starts more predictable.
- Images use literal `:latest` tags, except Gluetun, which tracks its newest stable release through `:v3` because its `latest` tag is a development build. Updates are manual and staged per service; follow [`docs/updating.md`](docs/updating.md) before pulling images or migrating data.
- Docker JSON logs are rotated by default to reduce slow NAS disk growth.
- No container has access to the Docker API, so the Homarr dashboard cannot read container settings or secrets.
- Homarr, Glances, and Gluetun telemetry are internal. nginx is the only Homarr entrypoint.
- nginx is intended for LAN use. Keep `BIND_IP` and `NGINX_PORT` behind your router and do not forward it publicly. Docker-published ports usually bypass the NAS host firewall, so the router is the boundary that matters.
- Seerr stays direct on its configured port. Do not forward that port publicly.
- If Docker is not on `PATH`, run manual compose commands with your host's `docker-compose` binary or export `DOCKER_COMPOSE_BIN`.
- Use only legally obtained media.
