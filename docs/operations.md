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

Docker JSON logs are rotated by the stack defaults:
- `LOG_MAX_SIZE=10m`
- `LOG_MAX_FILE=3`

nginx access logs use a sanitized format that records the path without query strings. This avoids storing sensitive playback or API query parameters in `nginx/logs/access.log`.

## Health and preflight

Run environment checks:
```bash
./scripts/doctor.sh
./scripts/security-check.sh
```

If you need to repair `.env` formatting or permissions explicitly:
```bash
./scripts/doctor.sh --fix-env
./scripts/security-check.sh --fix-env
```

Resync Homepage templates:
```bash
./scripts/sync-homepage-config.sh
```

Preview or protect Homepage syncs:
```bash
./scripts/sync-homepage-config.sh --dry-run
./scripts/sync-homepage-config.sh --backup
./scripts/sync-homepage-config.sh --skip-existing
```

Proxy health endpoint:
```bash
curl -fsS "http://localhost:${NGINX_PORT:-8090}/health"
```

Check container health states after a restart or update:
```bash
docker compose ps
```

Look for `healthy` on services with healthchecks before treating the stack as ready.

Security model:
- qBittorrent is the only service routed through Gluetun/Mullvad.
- nginx is intended for LAN use; router/NAS firewall rules should keep `NGINX_PORT` non-public.
- Jellyseerr stays direct on `JELLYSEERR_PORT`.

## Backup basics

Back up service configs before updates and on a regular schedule:
```bash
./scripts/backup-configs.sh
```

By default, archives are written to `${COMMON_PATH}/Backups` and include only app config folders:
- `Jellyfin/Config`
- `Jellyseerr/Config`
- `Sonarr/Config`
- `Radarr/Config`
- `Prowlarr/Config`
- `Qbittorrent/Config`
- `Homepage/Config`

Media libraries and downloads are excluded. To write backups somewhere else:
```bash
./scripts/backup-configs.sh --output-dir /path/to/backups
```

## Hardware acceleration checks

On Intel TerraMaster systems, Jellyfin expects `/dev/dri/renderD128` and a matching `JELLYFIN_RENDER_GID`.

Useful checks:
```bash
ls -l /dev/dri
getent group render
./scripts/doctor.sh
```

During a transcode, host tools such as `intel_gpu_top` can confirm whether the iGPU is active when available on your NAS.
