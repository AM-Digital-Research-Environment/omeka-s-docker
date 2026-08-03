# Docker Commands Reference

Quick reference for managing your Omeka S Docker setup.

## Starting & Stopping

```bash
# Start all services (detached)
docker compose up -d

# Stop all services (keeps data)
docker compose down

# Restart a specific service
docker compose restart php

# Restart all services
docker compose restart
```

## Viewing Logs

```bash
# All services (follow mode)
docker compose logs -f

# Specific service
docker compose logs -f php
docker compose logs -f web
docker compose logs -f db

# Last 100 lines only
docker compose logs --tail=100 php
```

## Service Status

```bash
# Check running containers and health
docker compose ps

# Detailed container info
docker inspect omeka-s-docker-php-1
```

## Rebuilding immutable code

```bash
# Build matching PHP/nginx images and restart application services
bash scripts/rebuild-code.sh

# Refresh floating module/theme refs, then deploy
bash scripts/rebuild-code.sh --refresh

# Build without replacing running containers
bash scripts/rebuild-code.sh --no-start
```

## Accessing Containers

```bash
# PHP container shell
docker compose exec php bash

# MySQL shell (prompts for password from .env)
docker compose exec db mysql -u omeka -p

# Run a one-off command
docker compose exec php php -v

# Run omeka-s-cli inside the container
docker compose exec php omeka-s-cli --help
```

> For a walk-through of common `omeka-s-cli` workflows (module updates, user
> management, vocabulary imports, resource templates, settings) see
> [OMEKA_CLI.md](OMEKA_CLI.md).

## ⚠️ Complete Reset (Fresh Install)

```bash
# Stop and remove containers, networks, AND volumes (DATA LOSS!)
docker compose down -v

# Then start fresh
docker compose up -d
```

## Disk Cleanup

```bash
# Remove unused containers, networks, images
docker system prune

# Remove everything including unused volumes (CAREFUL!)
docker system prune -a --volumes

# Remove only dangling images
docker image prune

# Remove only unused volumes
docker volume prune

# Check disk usage
docker system df
```

## Pulling Updates

```bash
# Pull published service images (MySQL/Typesense)
docker compose pull

# Refresh Dockerfile base images and rebuild Omeka code
bash scripts/rebuild-code.sh --pull
```

## Backup & Restore

```bash
# Full backup (database + files + sideload + .env)
# Zero-downtime; avoid module/core upgrades while it runs
bash scripts/backup.sh

# Backup to a custom directory
bash scripts/backup.sh /tmp/omeka-backup

# Restore from a backup
bash scripts/restore.sh backups/20260330-120000

# Non-interactive restore (destructive; intended for automation/CI)
bash scripts/restore.sh --force backups/20260330-120000
```

## Useful Combos

```bash
# Full restart with fresh build
docker compose down && docker compose up -d --build

# Nuclear option: complete reset and fresh install
docker compose down -v && docker compose up -d --build

# Quick health check
docker compose ps && docker compose logs --tail=20
```

## Environment Variables

```bash
# See resolved config (with .env applied)
docker compose config

# Override .env temporarily
NGINX_PORT=9000 docker compose up -d

# These are build arguments. Rebuild both images after changing them.
# EXTRA_MODULES=DspaceConnector,ValueSuggest,CSSEditor
# EXTRA_THEMES=Cozy,Foundation
# ENABLE_IIIF=true
bash scripts/rebuild-code.sh
```

## Module Management

```bash
# List available modules
./scripts/install-module.sh list

# Add an official module to the build manifest and deploy
./scripts/install-module.sh CSVImport

# Add a third-party module pinned to a tag/commit and deploy
./scripts/install-module.sh gh:owner/repository v1.2.3

# After editing a pin in _docker/extra-modules.txt, deploy it
./scripts/rebuild-code.sh

# Force floating refs to be downloaded again (prefer pins)
./scripts/update-module.sh

# Update Omeka S core (dry run first)
./scripts/update-omeka.sh --dry-run

# Update Omeka S core to latest
./scripts/update-omeka.sh

# Update Omeka S core to a specific version
./scripts/update-omeka.sh 4.2.1

# Activate/install DB state for code already baked into the image
docker compose exec php omeka-s-cli module:install --base-path /var/www/html ModuleName
docker compose exec php omeka-s-cli module:upgrade --base-path /var/www/html ModuleName
```

## Theme Management

```bash
# Add and deploy a pinned theme
./scripts/install-theme.sh gh:omeka-s-themes/CenterRow v1.8.0

# Or edit _docker/extra-themes.txt, then rebuild both images
./scripts/rebuild-code.sh
```

## Sideload (Bulk Imports)

```bash
# Place files in the sideload directory for bulk import
cp /path/to/files/* sideload/

# Then use FileSideload module in Omeka S admin panel
# Configure sideload directory: /var/www/html/sideload
```

## Troubleshooting

```bash
# Check container health status
docker inspect --format='{{json .State.Health}}' "$(docker compose ps -q php)"

# Inspect ownership, then restore least-privilege modes when owned by www-data
docker compose exec php id
docker compose exec php ls -ld /var/www/html/files
docker compose exec php chmod -R u=rwX,go=rX /var/www/html/files

# Clear writable runtime cache by recreating PHP (code remains immutable)
docker compose up -d --force-recreate php web

# Test database connection
docker compose exec db mysqladmin ping -u omeka -p
```
