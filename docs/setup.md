# Setup

## Prerequisites

- Linux host with Docker Engine
- Docker Compose (`docker compose` plugin or `docker-compose` binary)
- User permissions to run Docker
- Mullvad WireGuard details
- If Docker is not on `PATH`, set `DOCKER_BIN` and/or `DOCKER_COMPOSE_BIN` before running the helper scripts.

## Interactive setup (recommended)

```bash
./scripts/setup.sh
```

What it does:
- prompts for required settings
- writes `.env`
- creates missing media/config directories under `COMMON_PATH` and reuses existing folders safely
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

The sync target is `${COMMON_PATH}/Homepage/Config`.
Set `JELLYSEERR_EXTERNAL_URL` in `.env` to the browser-facing Jellyseerr URL if your clients do not access the stack through `localhost`.
Homepage also mounts the Docker socket read-only for container-aware widgets, so treat that container as more sensitive than the rest of the dashboard stack.

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

Notes:
- qBittorrent is the only service intentionally routed through Gluetun/Mullvad.
- nginx is intended for LAN use; keep `NGINX_PORT` behind your router/NAS firewall and set `NGINX_BIND_IP` if you want to bind only loopback or one LAN IP.
- Jellyseerr remains direct on `JELLYSEERR_PORT`, is not protected by nginx access rules, and can be constrained with `JELLYSEERR_BIND_IP`.
