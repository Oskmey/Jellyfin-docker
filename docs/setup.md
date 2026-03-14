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
- runs compose preflight validation (auto-detects `docker compose` or `docker-compose`, with override support)

## Non-interactive setup

Use this when provisioning through scripts or CI:

```bash
./scripts/setup.sh --non-interactive --env-file .env
```

Requirements:
- `.env` already exists
- all required variables are populated

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
- nginx is intended for LAN use; keep `NGINX_PORT` behind your router/NAS firewall.
- Jellyseerr remains direct on `JELLYSEERR_PORT` and is not protected by nginx access rules.
