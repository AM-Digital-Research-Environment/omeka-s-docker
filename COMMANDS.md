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

# MySQL shell
docker compose exec db mysql -u omeka -p omeka

# Run a one-off command
docker compose exec php php -v
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
# Backup MySQL database
docker compose exec db mysqldump -u omeka -p omeka > backup.sql

# Restore MySQL database
docker compose exec -T db mysql -u omeka -p omeka < backup.sql

# Backup Omeka files volume
docker run --rm -v omeka-s-docker_omeka_files:/data -v $(pwd):/backup alpine tar czf /backup/omeka-files.tar.gz -C /data .
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
```

## Module Management

```bash
# List available modules
./scripts/install-module.sh list

# Install a module
./scripts/install-module.sh AdvancedSearch

# Update a module
./scripts/update-module.sh CSVImport

# Update all modules
./scripts/update-module.sh all

# Update Omeka S core
./scripts/update-omeka.sh
```

## Troubleshooting

```bash
# Check container health status
docker inspect --format='{{json .State.Health}}' omeka-s-docker-php-1

# Fix file permissions
docker compose exec php chown -R www-data:www-data /var/www/html/files
docker compose exec php chmod -R 775 /var/www/html/files

# Clear Omeka cache
docker compose exec php rm -rf /var/www/html/data/cache/*
docker compose restart php

# Test database connection
docker compose exec db mysqladmin ping -u omeka -p
```
