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
- generates the Homarr encryption key and Gluetun telemetry API key when missing
- creates Homarr, Glances, and Gluetun configuration directories with restricted permissions
- runs compose preflight validation (auto-detects `docker compose` or `docker-compose`, with override support)

## Non-interactive setup

Use this when provisioning through scripts or CI:

```bash
./scripts/setup.sh --non-interactive --env-file .env
```

Requirements:
- `.env` already exists
- all required variables are populated

## Homarr configuration

Set the Homarr and Seerr browser URLs to the LAN addresses clients actually use. Setup generates Homarr's encryption key and the Gluetun telemetry key. Preserve both keys when migrating an existing installation.

Homarr is configured after first start because its database contains users and encrypted credentials. Follow [`homarr.md`](homarr.md) for the exact boards, integrations, privacy boundaries, appearance, and backup procedure.

## TerraMaster Docker Manager

On TOS 6/7, keep this stack as one Docker Manager project when possible. Use the repository's `docker-compose.yml` and `.env` together so service names, networks, healthchecks, and shared paths stay consistent.

Do not start by changing NAS kernel modules or graphics drivers if transcoding fails. First verify:
- `/dev/dri` exists on the NAS
- `/dev/dri/renderD128` exists
- `JELLYFIN_RENDER_GID` matches the host render group or the render device group
- Jellyfin playback settings are configured for Intel QSV or VA-API

## LAN binding

`BIND_IP=0.0.0.0` exposes the nginx and Seerr ports on all NAS interfaces, which is convenient for normal LAN use. Use `BIND_IP=127.0.0.1` for localhost-only testing.

Keep both exposed ports behind your NAS or router firewall. Do not forward nginx, Seerr, or the qBittorrent WebUI publicly.

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
- nginx is intended for LAN use. Keep `NGINX_PORT` behind your router or NAS firewall.
- Seerr remains direct on its configured port and is not protected by nginx access rules.
- The stack uses container healthchecks so dependent services wait for healthier upstreams during startup.
- Docker JSON logs are rotated with `LOG_MAX_SIZE` and `LOG_MAX_FILE` to reduce long-term NAS disk growth.
