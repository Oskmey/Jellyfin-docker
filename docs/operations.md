# Operations

If Docker is not on `PATH`, replace `docker compose` below with your host's compose binary.

## Start and stop

Start all services:
```bash
docker compose up -d
```

Stop all services:
```bash
docker compose down
```

Restart one service:
```bash
docker compose restart jellyfin
```

## Logs and status

Service status:
```bash
docker compose ps
```

Tail logs:
```bash
docker compose logs -f
```

Single service logs:
```bash
docker compose logs -f sonarr
```

## Health and preflight

Run environment checks:
```bash
./scripts/doctor.sh
./scripts/security-check.sh
```

Resync Homepage templates:
```bash
./scripts/sync-homepage-config.sh
```

Proxy health endpoint:
```bash
curl -fsS "http://localhost:${NGINX_PORT:-8090}/health"
```

Security model:
- qBittorrent is the only service routed through Gluetun/Mullvad.
- nginx is intended for LAN use; router/NAS firewall rules should keep `NGINX_PORT` non-public, and `NGINX_BIND_IP` can restrict which host interface listens.
- Jellyseerr stays direct on `JELLYSEERR_PORT`, and `JELLYSEERR_BIND_IP` can restrict which host interface listens.

## Backup basics

Back up `COMMON_PATH` regularly:
- `Jellyfin/Config`
- `Jellyseerr/Config`
- `Sonarr/Config`
- `Radarr/Config`
- `Prowlarr/Config`
- `Qbittorrent/Config`
- `Homepage/Config`

Example tar backup:
```bash
tar -czf media-stack-backup-$(date +%F).tar.gz "${COMMON_PATH}"
```
