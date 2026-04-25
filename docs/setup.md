# Setup

## Prerequisites

- Linux host with Docker Engine
- Docker Compose (`docker compose` plugin or `docker-compose` binary)
- User permissions to run Docker
- Mullvad WireGuard details
- Intel TerraMaster NAS users: TOS 6/7 with `/dev/dri` exposed for Jellyfin hardware acceleration
- If Docker is not on `PATH`, set `DOCKER_BIN` and/or `DOCKER_COMPOSE_BIN` before running the helper scripts.

## Interactive setup (recommended)

```bash
./scripts/setup.sh
```

What it does:
- prompts for required settings
- writes `.env`
- creates missing media/config directories under `COMMON_PATH` and reuses existing folders safely
- detects the host `render` group ID for Jellyfin when available
- syncs the repo-managed Homepage dashboard config into `${COMMON_PATH}/Homepage/Config`
- runs compose preflight validation (auto-detects `docker compose` or `docker-compose`, with override support)

## Non-interactive setup

Use this when provisioning through scripts or CI:

```bash
./scripts/setup.sh --non-interactive --env-file .env
```

Requirements:
- `.env` already exists
- all required variables are populated

## Homepage config sync

The repository now ships Homepage config templates in `homepage/`. Sync them into the mounted config directory with:

```bash
./scripts/sync-homepage-config.sh
```

Useful safety options:

```bash
./scripts/sync-homepage-config.sh --dry-run
./scripts/sync-homepage-config.sh --backup
./scripts/sync-homepage-config.sh --skip-existing
```

The sync target is `${COMMON_PATH}/Homepage/Config`.
Set `JELLYSEERR_EXTERNAL_URL` in `.env` to the browser-facing Jellyseerr URL if your clients do not access the stack through `localhost`.
Homepage also mounts the Docker socket read-only for container-aware widgets, so treat that container as more sensitive than the rest of the dashboard stack.

## TerraMaster Docker Manager

On TOS 6/7, keep this stack as one Docker Manager project when possible. Use the repository's `docker-compose.yml` and `.env` together so service names, networks, healthchecks, and shared paths stay consistent.

Do not start by changing NAS kernel modules or graphics drivers if transcoding fails. First verify:
- `/dev/dri` exists on the NAS
- `/dev/dri/renderD128` exists
- `JELLYFIN_RENDER_GID` matches the host render group or the render device group
- Jellyfin playback settings are configured for Intel QSV or VA-API

## LAN binding

`BIND_IP=0.0.0.0` exposes the nginx and Jellyseerr ports on all NAS interfaces, which is convenient for normal LAN use. Use `BIND_IP=127.0.0.1` for localhost-only testing.

Keep both exposed ports behind your NAS/router firewall. Do not forward nginx, Jellyseerr, or qBittorrent WebUI ports publicly.

## Start stack

```bash
docker compose up -d
```

If Docker is not on `PATH`, run your host's compose binary directly:
```bash
/path/to/docker-compose up -d
```

## Verify

```bash
./scripts/doctor.sh
./scripts/security-check.sh
curl -fsS "http://localhost:${NGINX_PORT:-8090}/health"
```

Both check scripts are read-only by default. If you want them to normalize `.env` line endings or tighten `.env` permissions when supported, rerun them with `--fix-env`.

Notes:
- qBittorrent is the only service intentionally routed through Gluetun/Mullvad.
- nginx is intended for LAN use; keep `NGINX_PORT` behind your router/NAS firewall.
- Jellyseerr remains direct on `JELLYSEERR_PORT` and is not protected by nginx access rules.
- The stack uses container healthchecks so dependent services wait for healthier upstreams during startup.
- Docker JSON logs are rotated with `LOG_MAX_SIZE` and `LOG_MAX_FILE` to reduce long-term NAS disk growth.
