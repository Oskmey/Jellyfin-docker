# Setup

## Prerequisites

- Linux host with Docker Engine
- Docker Compose plugin (`docker compose`)
- User permissions to run Docker
- Mullvad WireGuard details

## Interactive setup (recommended)

```bash
./scripts/setup.sh
```

What it does:
- prompts for required settings
- writes `.env`
- creates missing media/config directories under `COMMON_PATH` and reuses existing folders safely
- creates `Portainer/Data/portainer.key` if missing
- runs `docker compose config` preflight validation

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

## Verify

```bash
./scripts/doctor.sh
curl -fsS "http://localhost:${NGINX_PORT:-8090}/health"
```
