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
- nginx is intended for LAN use. Router or NAS firewall rules should keep `NGINX_PORT` non-public.
- Seerr stays direct on its configured port.
- Homarr is public only inside the trusted LAN. Its NAS Control Room board requires credentials.
- Glances, Docker telemetry, and Gluetun telemetry have no published host ports.

## Backup basics

Back up service configs before updates and on a regular schedule:
```bash
./scripts/backup-configs.sh
```

By default, archives are written to `${COMMON_PATH}/Backups` and include only app config folders:
- `Jellyfin/Config`
- Seerr application configuration
- `Sonarr/Config`
- `Radarr/Config`
- `Prowlarr/Config`
- `Qbittorrent/Config`
- `Homarr/AppData`
- `Glances/glances.conf`
- `Gluetun/Auth`

Media libraries and downloads are excluded. To write backups somewhere else:
```bash
./scripts/backup-configs.sh --output-dir /path/to/backups
```

Also create a consistent export from Homarr's built-in backup screen after board or integration changes. Keep `HOMARR_SECRET_ENCRYPTION_KEY` separately. It is required to decrypt restored integration credentials.

Validate an archive before restoring it:

```bash
./scripts/restore-configs.sh \
  --archive "${COMMON_PATH}/Backups/media-stack-configs-TIMESTAMP.tar.gz" \
  --dry-run
```

Stop the stack before a real restore. The restore command refuses to overwrite non-empty configuration folders unless you pass `--force`. Take a fresh backup before using that option.

The restore command never restores `.env`, the Gluetun API key, media libraries, or downloads.

## Hardware acceleration checks

On Intel TerraMaster systems, Jellyfin expects `/dev/dri/renderD128` and a matching `JELLYFIN_RENDER_GID`.

Useful checks:
```bash
ls -l /dev/dri
getent group render
./scripts/doctor.sh
```

During a transcode, host tools such as `intel_gpu_top` can confirm whether the iGPU is active when available on your NAS.
