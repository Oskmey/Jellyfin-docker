# Updating

## Standard update workflow

If Docker is not on `PATH`, replace `docker compose` below with your host's compose binary.

1. Pull latest repo changes
```bash
git pull
```

2. Create a config-only backup
```bash
./scripts/backup-configs.sh
```

3. Export a Homarr backup from its management screen and preserve `HOMARR_SECRET_ENCRYPTION_KEY` separately.

4. Review image tags in `docker-compose.yml`
- this repository currently tracks `:latest` tags, so pulls may update multiple services at once
- read release notes before major version jumps or before restarting services you depend on

5. Pull images
```bash
docker compose pull
```

6. Recreate containers
```bash
docker compose up -d
```

7. Validate
```bash
./scripts/doctor.sh
./scripts/security-check.sh
docker compose ps
```

Validation notes:
- `doctor.sh` and `security-check.sh` are read-only by default.
- Use `--fix-env` only if you want either script to normalize `.env` line endings or tighten permissions when supported.
- After `docker compose up -d`, give healthchecked services time to move to `healthy` before troubleshooting transient startup errors.
- On TerraMaster, rerun Jellyfin playback checks after image updates if you rely on Intel hardware acceleration.
- Confirm the public Home Cinema board has not gained private fields after a Homarr update.
- Confirm Docker write methods and Gluetun mutation routes remain blocked.

## Rollback

If a service breaks after a `:latest` update:

1. Pin the affected service in `docker-compose.yml` to a known-good image version tag or digest.
2. Pull the pinned image.
```bash
docker compose pull <service>
```
3. Restart that service.
```bash
docker compose up -d <service>
```
