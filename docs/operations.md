# Operations

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
```

Proxy health endpoint:
```bash
curl -fsS "http://localhost:${NGINX_PORT:-8090}/health"
```

## Backup basics

Back up `COMMON_PATH` regularly:
- `Jellyfin/Config`
- `Jellyseerr/Config`
- `Sonarr/Config`
- `Radarr/Config`
- `Prowlarr/Config`
- `Qbittorrent/Config`
- `Portainer/Data`

Example tar backup:
```bash
tar -czf media-stack-backup-$(date +%F).tar.gz "${COMMON_PATH}"
```
