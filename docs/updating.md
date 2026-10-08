# Updating

All 13 services deliberately use literal `:latest` image tags. Eight already floated; five previously pinned images now follow the same policy. Pulls are manual, staged per service, and gated by release notes and runtime checks. Inspect the image actually pulled before deploying it: a floating tag can change after this document is written.

## Release snapshot: 2026-10-08

| Service | Verified release/build behind the selected image |
| --- | --- |
| Jellyfin | [12.2](https://github.com/jellyfin/jellyfin/releases/tag/v12.2) |
| Seerr (`jellyseerr`) | [v3.5.0](https://github.com/seerr-team/seerr/releases/tag/v3.5.0) |
| Homarr | [v2.3.0](https://github.com/homarr-labs/homarr/releases/tag/v2.3.0) |
| Sonarr | 4.0.20.3014-ls326 |
| Radarr | 6.4.4.10685-ls319 |
| Prowlarr | 2.6.5.5623-ls163 |
| Bazarr | v1.6.2-ls367 |
| qBittorrent | 5.2.4 / libtorrent 2.0.15, ls479 |
| FlareSolverr | v3.5.2 |
| Glances | v4.5.7, minimal image |
| socket-proxy | 3.4.6-r0-ls101 |
| Gluetun | master build, revision `ded7fd059ca0150aec51f2baff2337133387204c` |
| nginx | 1.31.6 mainline, October 6 rebuild |

Gluetun `latest` is a master build, not the separate stable v3.41.3 release. nginx `latest` is mainline, not its stable branch. These distinctions remain deliberate under the requested tag policy. The snapshot records researched versions, not a promise of what a later pull will contain.

## Before the first migration

Review the release notes for the running and target versions. Update one service or one tightly coupled pair at a time; avoid a bulk `docker compose pull` followed by a bulk recreation.

Jellyfin 12 requires a supported starting point of 10.10.7 or 10.11.x; older installations need the documented bridge upgrade first. Resolve usernames differing only by letter case before migration. Remove incompatible plugins, preserve their configuration where needed, and reinstall compatible releases afterward. For Intro Skipper, the verified stable 12.x release is [12.0.4.0](https://github.com/intro-skipper/intro-skipper/releases/tag/12.0/v12.0.4.0); check compatibility again at deployment. Run a full library scan after migration, then test login, library results, subtitles, direct playback, and hardware transcoding. See the [Jellyfin 12 migration notes](https://jellyfin.org/posts/jellyfin-release-12.0/).

Homarr 1.x to 2.x migrates the default SQLite database automatically. Preserve the complete stopped AppData directory and the same encryption key before starting 2.x. An installation using MySQL needs the separately documented conversion procedure; do not apply the SQLite workflow to it. See [Homarr Docker migration guidance](https://homarr.dev/docs/getting-started/installation/docker/) and the [MySQL converter procedure](https://homarr.dev/docs/advanced/mysql-to-sqlite/).

For Seerr, confirm that existing `Jellyseerr/Config` files are writable by the configured `PUID:PGID`. The previous official image defaults to UID 1000; setup does not automatically change existing ownership. Keep the existing service name and config directory.

Other compatibility checks before their respective stages:

- [Radarr 6](https://github.com/Radarr/Radarr/releases/tag/v6.0.0.10217) and [Prowlarr 2](https://github.com/Prowlarr/Prowlarr/releases/tag/v2.0.0.5094) remove Basic authentication and 32-bit Linux support. Check the Forms migration, custom Radarr folder formats, and Prowlarr Usenet redirects. Test both browser-facing hosts and internal service URLs instead of disabling host validation.
- [qBittorrent 5.2](https://github.com/qbittorrent/qBittorrent/releases/tag/release-5.2.0) changes session cookies and empty API responses. Test Sonarr/Radarr authentication, queue handling, and imports; LSIO's newer packaging must also work on the NAS.
- [Seerr 3.5](https://github.com/seerr-team/seerr/releases/tag/v3.5.0) moves library sync and toggles to POST/PUT endpoints. Update direct API consumers if present; the web UI uses the new contract.
- [Bazarr 1.6.2](https://github.com/morpheus65535/bazarr/releases/tag/v1.6.2) changes post-processing argument handling. Check commands containing spaces, quotes, or placeholders. Validate FlareSolverr against the indexers that actually use it.

## Create a complete checkpoint

Before each stage, record every service's running image reference, immutable image ID, and available repository digests in a private checkpoint file. Use targeted inspection fields so container environment secrets are not dumped:

```bash
docker compose ps -q | xargs -r docker inspect \
  --format '{{.Name}} {{.Config.Image}} {{.Image}}'
docker compose images -q | sort -u | xargs -r docker image inspect \
  --format '{{.Id}} {{json .RepoDigests}}'
```

Save the output outside Git alongside a copy of the corresponding Compose definition. Keep the old images available until validation completes. Back up `.env` and the Homarr encryption key separately with restricted access. Create a Homarr export while its UI is available, then stop all configuration writers and archive the full allowlisted configuration checkpoint:

```bash
docker compose stop
./scripts/backup-configs.sh
```

Do not use a live raw SQLite copy as the migration checkpoint. Media and downloads are excluded; Gluetun auth is regenerated from the separately preserved key. See [`operations.md`](operations.md) for archive contents.

## Deploy one stage

Pull only the selected service, review its actual image metadata/release compatibility, then recreate it:

```bash
docker compose pull <service>
docker compose up -d --no-deps --pull never <service>
docker compose ps
```

Use `--pull never` during recreation so it uses the image just reviewed; a floating tag must not be fetched again between review and startup. Start unchanged existing containers with `docker compose start` so integrations can be tested without recreating them from changed Compose settings. For Gluetun, treat qBittorrent as a coupled stage:

```bash
docker compose pull gluetun qbittorrent
# Review the pulled images before starting either container.
docker compose up -d --force-recreate --pull never gluetun qbittorrent
```

Retain `VPN_INTERFACE=tun0`, then check tunnel listeners, egress, and metadata/download traffic. A healthy qBittorrent WebUI alone does not prove its torrent traffic works.

Run the applicable gates before another pull:

- `./scripts/doctor.sh` and `./scripts/security-check.sh`; both are read-only unless `--fix-env` is requested.
- Browser login and authenticated internal integrations for the upgraded app.
- Sonarr/Radarr download-client tests, import paths, and hardlinks on an existing imported file; retain the shared `/data` mount.
- Jellyfin wizard/login at `/jellyfin/web/index.html`, empty app Base URL, playback, subtitle and GPU checks. nginx continues stripping the prefix.
- Homarr users, boards, encrypted integrations and telemetry; confirm the public board gained no private fields.
- Docker write/lifecycle and sensitive read operations stay blocked; Gluetun mutation routes remain denied.

Healthchecks report liveness/readiness and startup dependencies gate only declared relationships. They do not restart an unhealthy process or replace these functional checks. Keep nginx's asset-copy startup behavior: it is an intentional NAS permission workaround.

## Rollback after a migration

Never downgrade only the image against migrated data. Stop configuration writers, preserve the failed state for diagnosis, validate the pre-stage archive with `restore-configs.sh --dry-run`, and restore that checkpoint with the matching pre-stage image references/digests. Since the archive contains the whole allowlisted config checkpoint, align all restored apps with their recorded pre-stage images. `--force` is an explicit overwrite operation; use it only after the failed state is preserved and the restore paths are reviewed.

Keep `.env` and its encryption key consistent with restored data, and regenerate required auth/config files through non-interactive setup when recovering on a new host. Recreate services, run the same gates, and retain the checkpoint until recovery is verified. A mutable `latest` tag is not a rollback identity.
