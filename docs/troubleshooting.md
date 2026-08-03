# Troubleshooting

If Docker is not on `PATH`, replace `docker compose` below with your host's compose binary.

## docker compose config fails with missing variable

Cause:
- required env values are not set in `.env`

Fix:
```bash
./scripts/setup.sh
./scripts/doctor.sh
```

## Services start but route returns 502

Cause:
- upstream service is not healthy or still starting

Fix:
```bash
docker compose ps
docker compose logs -f <service>
```

Notes:
- Immediately after startup, wait for healthchecks to settle before assuming a persistent proxy issue.
- `docker compose ps` should show `healthy` for the services that nginx or Seerr depend on.

## Homarr loads but a widget is unavailable

Cause:
- the application integration URL or API key is wrong
- the upstream is still starting
- the Glances, Docker proxy, or Gluetun integration is using a browser URL instead of its internal Docker URL

Fix:
```bash
docker compose ps
docker compose logs --tail 100 homarr glances docker-socket-proxy gluetun
```

Compare the integration URL with [`homarr.md`](homarr.md). Do not publish an internal telemetry port to work around an integration error.

If a public widget reveals an internal URL, username, request detail, download name, VPN address, filesystem, or raw error, remove it from **Home Cinema** immediately and keep it only on the private board after verifying its fields.

## qBittorrent cannot connect or has no VPN tunnel

Cause:
- invalid WireGuard values
- VPN endpoint blocked

Fix:
- verify `WIREGUARD_*` values in `.env`
- run the security verification script:
```bash
./scripts/security-check.sh
```
- if the script warns about `.env` formatting or permissions and you want it repaired automatically:
```bash
./scripts/security-check.sh --fix-env
```
- check Gluetun logs:
```bash
docker compose logs -f gluetun
```

## qBittorrent WebUI login is unknown

Cause:
- recent qBittorrent versions generate a temporary first-run password
- an existing config has a changed or forgotten WebUI password

Fix:
- check qBittorrent logs for the temporary password on first start:
```bash
docker compose logs qbittorrent
```
- after login, change the WebUI password immediately
- keep the WebUI reachable only through the LAN nginx route

## Permission denied on media paths

Cause:
- `PUID`/`PGID` mismatch with host filesystem ownership

Fix:
- set `PUID` and `PGID` in `.env` to your Linux user/group IDs
- ensure `COMMON_PATH` is writable by that user

## Jellyfin hardware acceleration is unavailable

Cause:
- TerraMaster is not exposing the Intel render device
- `JELLYFIN_RENDER_GID` does not match the host render group
- Jellyfin playback settings are not using QSV or VA-API

Fix:
```bash
ls -l /dev/dri
getent group render
./scripts/doctor.sh
```

Set `JELLYFIN_RENDER_GID` in `.env` to the host render group ID or the group ID shown for `/dev/dri/renderD128`, then recreate Jellyfin:
```bash
docker compose up -d jellyfin
```

Avoid kernel or driver changes as a first step on TOS 6/7. Confirm the device, group, and Jellyfin settings first.

For poor 4K playback, confirm hardware acceleration is enabled inside Jellyfin itself:
- Jellyfin Dashboard -> Playback -> Transcoding -> Hardware acceleration: `Intel Quick Sync`
- QSV/VA-API device: `/dev/dri/renderD128`
- enable hardware decoding for common 4K codecs such as HEVC and VP9
- enable hardware tone mapping when HDR content must play on SDR clients

If transcoding starts, verify it is using the iGPU:
```bash
docker compose logs --tail 80 jellyfin
docker compose exec jellyfin sh -lc 'ls -l /dev/dri && /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -hwaccels'
```

## Jellyfin posters or metadata images fail

Cause:
- Jellyfin metadata files are not owned by the same `PUID`/`PGID` used by the container

Fix:
```bash
set -a
. ./.env
set +a
chown -R "${PUID}:${PGID}" "${COMMON_PATH}/Jellyfin/Config/metadata"
docker compose restart jellyfin
```

## Jellyfin does not see media

Cause:
- wrong library paths
- files landed in unexpected directories

Fix:
- Jellyfin library paths must be `/data/tvshows` and `/data/movies`
- verify download and import paths in Sonarr/Radarr
- trigger a manual library scan in Jellyfin

## nginx config issues

Check syntax:
```bash
docker compose exec nginx-proxy nginx -t
```

Check health endpoint:
```bash
curl -fsS "http://localhost:${NGINX_PORT:-8090}/health"
```

Verify proxy routes locally:
```bash
./scripts/security-check.sh
```
