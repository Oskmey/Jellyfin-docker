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
- `docker compose ps` should show `healthy` for the services that nginx or Jellyseerr depend on.

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

## Permission denied on media paths

Cause:
- `PUID`/`PGID` mismatch with host filesystem ownership

Fix:
- set `PUID` and `PGID` in `.env` to your Linux user/group IDs
- ensure `COMMON_PATH` is writable by that user

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
