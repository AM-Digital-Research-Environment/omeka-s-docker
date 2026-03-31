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

## Rebuilding (after Dockerfile changes)

```bash
# Rebuild and restart
docker compose up -d --build

# Force rebuild without cache
docker compose build --no-cache
docker compose up -d
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
# Pull latest images (nginx, mysql)
docker compose pull

# Pull and restart with new images
docker compose pull && docker compose up -d
```

## Backup & Restore

```bash
# Full backup (database + files + sideload + .env)
# Stops containers during backup for consistency, then restarts
bash scripts/backup.sh

# Backup to a custom directory
bash scripts/backup.sh /tmp/omeka-backup

# Restore from a backup
bash scripts/restore.sh backups/20260330-120000
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

# Install extra modules/themes at runtime (set in .env)
# EXTRA_MODULES=DspaceConnector,ValueSuggest,CSSEditor
# EXTRA_THEMES=Cozy,Foundation
# ENABLE_IIIF=true
docker compose down && docker compose up -d
```

## Module Management

```bash
# List available modules
./scripts/install-module.sh list

# Install a module
./scripts/install-module.sh AdvancedSearch

# Install a module at a specific version
./scripts/install-module.sh AdvancedSearch 3.5.46

# Update a module
./scripts/update-module.sh CSVImport

# Update all modules
./scripts/update-module.sh all

# Update Omeka S core (dry run first)
./scripts/update-omeka.sh --dry-run

# Update Omeka S core to latest
./scripts/update-omeka.sh

# Update Omeka S core to a specific version
./scripts/update-omeka.sh 4.2.0

# Install modules via omeka-s-cli inside the container
docker compose exec php omeka-s-cli module:download --base-path /var/www/html ModuleName
docker compose exec php omeka-s-cli module:install --base-path /var/www/html ModuleName
```

## Theme Management

```bash
# Install a theme
./scripts/install-theme.sh CenterRow

# Install a theme at a specific version
./scripts/install-theme.sh Foundation 1.4.0
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

# Fix file permissions
docker compose exec php chown -R www-data:www-data /var/www/html/files
docker compose exec php chmod -R 775 /var/www/html/files

# Clear Omeka cache
docker compose exec php rm -rf /var/www/html/data/cache/*
docker compose restart php

# Test database connection
docker compose exec db mysqladmin ping -u omeka -p
```
