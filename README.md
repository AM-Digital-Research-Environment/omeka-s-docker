# Omeka S Docker Template

A reusable Docker template for deploying Omeka S digital archive installations. This template provides a production-ready setup with automatic installation, optimized PHP configuration, and comprehensive module management scripts.

## Features

- **Automatic Installation**: Omeka S is automatically installed on first run
- **Optimized PHP 8.4**: Pre-configured with OPcache, APCu, and ImageMagick
- **Production-Ready Nginx**: Gzip compression, security headers, CORS for IIIF
- **Module Management**: Scripts for installing and updating modules
- **Health Checks**: All services include Docker health checks

## Prerequisites

- Docker and Docker Compose v2+
- Git (for cloning this template)

## Project Structure

```
.
├── docker-compose.yml          # Main service orchestration
├── Dockerfile                  # PHP-FPM container configuration
├── nginx.conf                  # Nginx web server configuration
├── uploads.ini                 # PHP upload settings
├── docker-entrypoint.sh        # PHP container initialization & auto-install
├── .env.example                # Environment variables template
├── scripts/
│   ├── install-module.sh       # Install new modules
│   ├── update-module.sh        # Update existing modules
│   └── update-omeka.sh         # Update Omeka S core
└── sideload/                   # Bulk import directory
```

## Services Overview

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| **web** | nginx:1.27-alpine | 80 | Reverse proxy, static files |
| **php** | PHP 8.4-FPM | 9000 (internal) | Omeka S application |
| **db** | MySQL 9.4 | 3306 (internal) | Database |

## Quick Start

### 1. Clone and Configure

```bash
# Clone this template
git clone <repository-url> my-omeka-site
cd my-omeka-site

# Create environment file
cp .env.example .env

# Edit .env with your secure password
nano .env
```

### 2. Start Services

```bash
# Start all services (Omeka S will auto-install on first run)
docker compose up -d

# Watch the installation progress
docker compose logs -f php
```

### 3. Complete Setup

1. Wait for all services to show as "healthy":
   ```bash
   docker compose ps
   ```

2. Open your browser to `http://localhost` (or your server IP)

3. Complete the Omeka S web installation wizard

### 4. Install Modules (Optional)

```bash
# List available modules
./scripts/install-module.sh list

# Install a module
./scripts/install-module.sh CSVImport
./scripts/install-module.sh FileSideload
```

## Environment Variables

Create a `.env` file with:

```bash
# Required
MYSQL_PASSWORD=your_secure_mysql_password

# Optional
OMEKA_VERSION=latest    # or specific version like 4.2.0
NGINX_PORT=80           # change if port 80 is in use
```

## Key Configuration

### PHP Settings
- Memory limit: 1024MB
- Upload limit: 100MB
- Max execution time: 300s
- OPcache with JIT enabled
- APCu caching enabled

### MySQL Settings
- Authentication: mysql_native_password
- InnoDB buffer pool: 512MB
- Max connections: 100

### Nginx Settings
- Gzip compression enabled
- Security headers (X-Frame-Options, etc.)
- CORS headers for IIIF endpoints
- Static file caching (1 year)

## Common Operations

### View Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f php
docker compose logs -f web
docker compose logs -f db
```

### Restart Services

```bash
# Single service
docker compose restart php

# All services
docker compose down && docker compose up -d
```

### Access Container Shell

```bash
# PHP container
docker compose exec php bash

# MySQL
docker compose exec db mysql -u omeka -p
```

### Update Omeka S Core

```bash
# Preview update (dry run)
./scripts/update-omeka.sh --dry-run

# Update to latest version
./scripts/update-omeka.sh

# Update to specific version
./scripts/update-omeka.sh 4.2.0
```

### Update Modules

```bash
# Update a specific module
./scripts/update-module.sh CSVImport

# Update all modules
./scripts/update-module.sh all
```

## Module Installation

### Available Modules

The scripts support many popular modules including:

**Official Omeka S Modules:**
- CSVImport, FileSideload, Mapping, CustomVocab
- FacetedBrowse, NumericDataTypes, Collecting
- DataCleaning, Hierarchy, InverseProperties

**Daniel-KM Modules:**
- AdvancedSearch, BulkEdit, BulkExport
- IiifServer, ImageServer, UniversalViewer
- Common, Log, EasyAdmin, Reference

Run `./scripts/install-module.sh list` to see all available modules.

### Module Dependencies

Some modules have dependencies. Install in this order if using Daniel-KM modules:

1. Common (required by many Daniel-KM modules)
2. Log (required by some modules)
3. Other modules as needed

## IIIF Support

The nginx configuration includes full CORS support for IIIF endpoints:
- `/iiif/` - IIIF Image API
- `/files/` - Media files
- `/api/` - Omeka S API

This allows external IIIF viewers (Mirador, Universal Viewer) to access your content.

## Bulk Imports

Use the `sideload/` directory for bulk file imports:

1. Place files in the `sideload/` directory
2. Install FileSideload module: `./scripts/install-module.sh FileSideload`
3. Configure FileSideload in Omeka S admin to point to `/var/www/html/sideload`
4. Import files through the Omeka S admin interface

## Troubleshooting

### Service Won't Start

```bash
# Check logs
docker compose logs php

# Check health status
docker compose ps
docker inspect <container-name> --format '{{json .State.Health}}'
```

### Database Connection Issues

```bash
# Test database connection
docker compose exec db mysql -u omeka -p -e "SELECT 1"

# Check database exists
docker compose exec db mysql -u omeka -p -e "SHOW DATABASES"
```

### Permission Issues

```bash
# Fix file permissions
docker compose exec php chown -R www-data:www-data /var/www/html/files
docker compose exec php chmod -R 775 /var/www/html/files
```

### Clear Cache

```bash
docker compose exec php rm -rf /var/www/html/data/cache/*
docker compose restart php
```

## Security Notes

- Store passwords in `.env` file (never commit to git)
- MySQL uses random root password
- Security headers are configured in nginx
- Consider adding SSL/TLS termination via reverse proxy

## Volumes

Data is persisted in Docker volumes:

| Volume | Purpose |
|--------|---------|
| `mysql_data` | MySQL database files |
| `omeka_files` | Omeka S installation and uploads |

## Backup

To backup your installation:

```bash
# Database backup
docker compose exec db mysqldump -u omeka -p omeka > backup.sql

# Files backup (from host)
docker run --rm -v omeka-s-docker-template_omeka_files:/data -v $(pwd):/backup alpine tar czf /backup/omeka-files.tar.gz /data
```

## Adding Solr Search (Optional)

If you need full-text search, see the [IWAC-docker](https://github.com/fmadore/IWAC-docker) repository for a complete example with Solr integration.

## License

This template is based on the [Islam West Africa Collection (IWAC) Docker setup](https://github.com/fmadore/IWAC-docker).
