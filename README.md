# Jellyfin Docker NAS Stack

A Linux-first, self-hosted media server stack built around Jellyfin and Docker.

It includes:
- Streaming: Jellyfin
- Requests: Jellyseerr
- Library automation: Sonarr, Radarr, Prowlarr, Bazarr
- Dashboard: Homepage
- Downloader behind VPN: qBittorrent + Gluetun
- Admin tools: Portainer and FlareSolverr
- Local entrypoint: nginx reverse proxy (Jellyseerr is direct on its own port)

## Goals

- Easy to set up for first-time self-hosters
- Easy to run and maintain long-term
- Clear defaults with predictable behavior
- Reliable local LAN deployment

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
This generates `.env`, creates only missing data folders (reusing existing ones), and validates your Compose config.

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
- `NGINX_PORT` (default `8090`)
- `JELLYSEERR_PORT` (default `5055`)
- `DNS` (default `1.1.1.1`)
- `SERVER_COUNTRIES` (default `Sweden`)
- `NGINX_ALLOWED_CIDRS` (default loopback + RFC1918/private ranges)
- `HOMEPAGE_ALLOWED_HOSTS` (default `*` for local-only setups)

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

## Documentation

- Setup details: [`docs/setup.md`](docs/setup.md)
- First-run wiring: [`docs/first-run.md`](docs/first-run.md)
- Operations: [`docs/operations.md`](docs/operations.md)
- Updating and rollback: [`docs/updating.md`](docs/updating.md)
- Troubleshooting: [`docs/troubleshooting.md`](docs/troubleshooting.md)

## Repository Layout

- `docker-compose.yml`: stack definition
- `.env.example`: config template
- `scripts/setup.sh`: interactive setup + env generation
- `scripts/doctor.sh`: environment and compose validation
- `scripts/security-check.sh`: VPN and LAN-only routing verification
- `nginx/conf.d/default.conf`: reverse proxy routes
- `docs/`: onboarding, operations, and troubleshooting

## Notes

- This project is HTTP-only for local self-hosting.
- qBittorrent is intentionally routed through Gluetun VPN.
- nginx routes are intentionally LAN-only; tune them with `NGINX_ALLOWED_CIDRS` and do not forward `NGINX_PORT` publicly.
- Jellyseerr stays direct on `JELLYSEERR_PORT`; if you keep that port, do not forward it publicly.
- If Docker is not on `PATH`, run manual compose commands with your host's `docker-compose` binary or export `DOCKER_COMPOSE_BIN`.
- Use only legally obtained media.
