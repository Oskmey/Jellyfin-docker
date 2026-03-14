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

3. Review pinned image tags in `docker-compose.yml`
- update only the services you want to upgrade
- read release notes before major version jumps

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
