# Updating

## Standard update workflow

1. Pull latest repo changes
```bash
git pull
```

2. Review pinned image tags in `docker-compose.yml`
- update only the services you want to upgrade
- read release notes before major version jumps

3. Pull images
```bash
docker compose pull
```

4. Recreate containers
```bash
docker compose up -d
```

5. Validate
```bash
./scripts/doctor.sh
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
