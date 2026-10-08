# Operations

If Docker is not on `PATH`, replace `docker compose` below with your host's compose binary.

## Start and stop

Start all services using locally available images:
```bash
docker compose up -d --pull never
```
For a first installation, follow [`setup.md`](setup.md). For image changes, use the staged procedure in [`updating.md`](updating.md).

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

nginx access logs record the path without query strings or Referer headers. View them with `docker compose logs nginx-proxy`; Docker applies the rotation settings above.

nginx error logs can still contain full request URLs and headers during failures. Treat those logs as sensitive and redact tokens before sharing them.

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
The nginx `/health` endpoint checks proxy liveness, not upstream readiness. App checks do not prove authenticated integrations, imports, VPN traffic, or playback. An unhealthy state alone does not trigger `restart: unless-stopped`; that policy handles process exits. Startup dependencies apply only where Compose declares them. After recreating Gluetun, recreate its dependent qBittorrent container and verify tunnel listeners and download traffic.

Security model:
- qBittorrent is the only service routed through Gluetun/Mullvad.
- nginx is intended for LAN use. Router or NAS firewall rules should keep `NGINX_PORT` non-public.
- Seerr stays direct on its configured port.
- Homarr is public only inside the trusted LAN. Its NAS Control Room board requires credentials.
- Glances, Docker telemetry, and Gluetun telemetry have no published host ports.
- Docker telemetry uses a trusted administrator integration. Read-only container inspection can expose environment secrets even when write, archive, export, logs, process, and lifecycle operations are denied; keep credentials and this integration off the public board.

## Backup basics

For a consistent raw backup, stop the configuration writers first. Before an upgrade, follow the image checkpoint and migration gates in [`updating.md`](updating.md):
```bash
docker compose stop
./scripts/backup-configs.sh
```
Restart existing containers with `docker compose start` after a routine backup. Follow the update gate before recreating containers for a migration.

By default, archives are written to `${COMMON_PATH}/Backups` and include only app config folders:
- `Jellyfin/Config`
- Seerr application configuration
- `Sonarr/Config`
- `Radarr/Config`
- `Prowlarr/Config`
- `Bazarr/Config`
- `Qbittorrent/Config`
- `Homarr/AppData`
- `Glances/glances.conf`
- legacy `Homepage/Config`, when present, for existing backup compatibility

Gluetun auth configuration is generated from the separately preserved telemetry key and is excluded. Keep `.env` and its secrets in a separate secure backup.

App archives can still contain saved credentials and API keys. Keep them outside Git, with restricted access, and copy important checkpoints off the NAS.

Media libraries and downloads are excluded. To write backups somewhere else:
```bash
./scripts/backup-configs.sh --output-dir /path/to/backups
```

Before stopping services, also create a Homarr export after board or integration changes. Keep `HOMARR_SECRET_ENCRYPTION_KEY` separately; it is required to decrypt restored integration credentials. The stopped full AppData archive is the migration checkpoint.

Validate an archive before restoring it:

```bash
./scripts/restore-configs.sh \
  --archive /path/to/media-stack-configs-TIMESTAMP.SUFFIX.tar.gz \
  --dry-run
```

Stop the stack before a real restore. The restore command refuses to overwrite non-empty configuration folders unless you pass `--force`. Take a fresh backup before using that option.

Archived configuration targets are replaced, not merged: `--force` removes destination-only files inside those targets. Unarchived targets, sibling cache/media directories, and existing parent permissions are preserved. New backups include a unique suffix and publish only after archive creation succeeds.

Restore rejects symlinked service/configuration destinations and targets on a different filesystem from `COMMON_PATH`, so replacements can use same-filesystem renames. Use an application-native restore for separately mounted configuration paths. If replacement fails, the script restores displaced targets; if recovery itself fails, it reports the staging path and preserves the originals there for manual recovery.

The restore command never restores `.env`, Gluetun auth/API key, media libraries, or downloads. Regenerate auth files through setup using the preserved key when recovering on a new host. A database migration rollback requires matching pre-upgrade images and data, not an image downgrade alone.

## Hardware acceleration checks

On Intel TerraMaster systems, Jellyfin expects `/dev/dri/renderD128` and a matching `JELLYFIN_RENDER_GID`.

Useful checks:
```bash
ls -l /dev/dri
getent group render
stat -c '%g' /dev/dri/renderD128
./scripts/doctor.sh
```

During a transcode, host tools such as `intel_gpu_top` can confirm whether the iGPU is active when available on your NAS.
Use the actual render device's numeric group if it differs from the named `render` group. `/dev/dri` access and a matching supplemental group are needed in addition to enabling QSV/VA-API in Jellyfin; an available encoder list alone does not prove a hardware transcode works.
