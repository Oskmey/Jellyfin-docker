# Updating

## Standard update workflow

If Docker is not on `PATH`, replace `docker compose` below with your host's compose binary.

1. Pull latest repo changes
```bash
git pull
```

2. Sync Homepage templates
```bash
./scripts/sync-homepage-config.sh
```

3. Review image tags in `docker-compose.yml`
- this repository currently tracks `:latest` tags, so pulls may update multiple services at once
- read release notes before major version jumps or before restarting services you depend on

4. Pull images
```bash
docker compose pull
```

5. Recreate containers
```bash
docker compose up -d
```

6. Validate
```bash
./scripts/doctor.sh
./scripts/security-check.sh
docker compose ps
```

Validation notes:
- `doctor.sh` and `security-check.sh` are read-only by default.
- Use `--fix-env` only if you want either script to normalize `.env` line endings or tighten permissions when supported.
- After `docker compose up -d`, give healthchecked services time to move to `healthy` before troubleshooting transient startup errors.

## Rollback

If a service breaks after tag update:

1. Revert the changed image tag in `docker-compose.yml`
2. Pull the reverted tag
```bash
docker compose pull <service>
```
3. Restart that service
```bash
docker compose up -d <service>
```
