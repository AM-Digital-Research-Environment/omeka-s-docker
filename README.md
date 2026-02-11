# Omeka S Docker Template

A reusable Docker template for deploying Omeka S digital archive installations. This template provides a production-ready setup with automatic installation, optimized PHP configuration, and comprehensive module management scripts.

## Features

- **Automatic Installation**: Omeka S is automatically installed on first run
- **Pre-installed Modules**: Common modules included by default
- **Optimized PHP 8.4**: Pre-configured with OPcache, APCu, and ImageMagick
- **Multi-stage Build**: Lean production image with pinned ImageMagick version
- **Non-root Execution**: PHP-FPM workers run as www-data via pool configuration
- **Network Isolation**: Separate frontend/backend networks isolate PHP and MySQL
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
├── Dockerfile                  # Multi-stage PHP-FPM container build
├── nginx.conf                  # Nginx web server configuration
├── uploads.ini                 # PHP upload settings
├── docker-entrypoint.sh        # PHP container initialization & auto-install
├── ensure-composer.sh          # On-demand Composer installer
├── .env.example                # Environment variables template
├── COMMANDS.md                 # Docker commands quick reference
├── docs/
│   └── DB_TUNING.md            # MySQL tuning parameter reference
├── scripts/
│   ├── install-module.sh       # Install new modules
│   ├── update-module.sh        # Update existing modules
│   └── update-omeka.sh         # Update Omeka S core
└── sideload/                   # Bulk import directory
```

## Services Overview

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| **web** | nginx:1.28-alpine | 80 | Reverse proxy, static files |
| **php** | PHP 8.4-FPM | 9000 (internal) | Omeka S application |
| **db** | MySQL 8.4 | 3306 (internal) | Database |

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

### 4. Install Additional Modules (Optional)

Common modules (CSVImport, FileSideload, Mapping, etc.) are pre-installed. To add more:

```bash
# List available modules
./scripts/install-module.sh list

# Install additional modules
./scripts/install-module.sh AdvancedSearch
./scripts/install-module.sh BulkEdit
```

## Environment Variables

Create a `.env` file with:

```bash
# Required
MYSQL_PASSWORD=your_secure_mysql_password

# Optional
OMEKA_VERSION=4.2.0    # or specific version (default: 4.2.0)
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
- InnoDB buffer pool: 512MB
- Max connections: 250
- See [docs/DB_TUNING.md](docs/DB_TUNING.md) for full parameter reference

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

### Pre-installed Modules

The following modules are automatically installed with Omeka S:

| Module | Purpose |
|--------|---------|
| **ActivityLog** | Track user activity and changes |
| **CSVImport** | Import items from CSV files |
| **DataCleaning** | Batch clean and normalize data |
| **FacetedBrowse** | Create faceted search pages |
| **FileSideload** | Import files from server directory |
| **Mapping** | Add geographic locations to items |
| **NumericDataTypes** | Support for numeric and date values |

These modules are ready to activate in the Omeka S admin panel after installation.

### Additional Modules

The scripts support many additional modules including:

**Official Omeka S Modules:**
- CSVImport, FileSideload, Mapping, CustomVocab
- FacetedBrowse, NumericDataTypes, Collecting
- DataCleaning, Hierarchy, InverseProperties

**Daniel-KM Modules:**
- AdvancedSearch, BulkEdit, BulkExport
- IiifServer, ImageServer, UniversalViewer
- Common, Log, Cron, EasyAdmin, Reference

Run `./scripts/install-module.sh list` to see all available modules.

### Module Dependencies

Dependencies are **automatically installed** when you install a module that requires them. For example:

```bash
# This will automatically install Common and Cron first, then EasyAdmin
./scripts/install-module.sh EasyAdmin
```

The script will:
1. Check if required dependencies are installed
2. Install missing dependencies in the correct order
3. Install the requested module
4. Display a reminder to activate modules in the correct order in Omeka S admin

**Modules with automatic dependencies:**

| Module | Dependencies |
|--------|--------------|
| EasyAdmin | Common, Cron |
| AdvancedSearch | Common |
| BulkEdit | Common |
| BulkExport | Common |
| SearchSolr | Common, AdvancedSearch |
| IiifServer | Common |
| ImageServer | Common |
| UniversalViewer | Common |
| Log | Common |
| Reference | Common |
| OaiPmhRepository | Common |

**Activation order in Omeka S admin:**
When activating modules with dependencies, always activate them in order:
1. Common (first)
2. Other dependencies (Cron, Log, AdvancedSearch, etc.)
3. The module you want to use (EasyAdmin, SearchSolr, etc.)

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
- Use a reverse proxy for SSL/TLS in production (see below)

## Security Hardening (Built-in)

This template includes Docker security hardening by default in the main `docker-compose.yml`:

| Feature | Description |
|---------|-------------|
| **Resource Limits** | CPU and memory limits prevent DoS attacks |
| **no-new-privileges** | Prevents privilege escalation inside containers |
| **Dropped Capabilities** | Removes unnecessary Linux capabilities |
| **Read-only Filesystems** | nginx runs with read-only root filesystem |
| **Network Isolation** | Separate frontend/backend networks; only nginx is exposed |
| **Non-root Execution** | PHP-FPM workers run as www-data via pool configuration |

### Security Considerations for Docker in Production

#### Known Limitations

| Concern | Risk | Mitigation |
|---------|------|------------|
| **Shared Kernel** | Kernel exploit affects all containers | Keep host OS updated, use minimal host |
| **Container Breakout** | Compromised container may access host | Never use `--privileged`, drop capabilities |
| **Image Vulnerabilities** | Base images may contain CVEs | Scan images with Docker Scout or Trivy |
| **Secrets in Environment** | `docker inspect` exposes env vars | Use Docker secrets for sensitive data |
| **Docker Socket** | Mounting socket = root on host | Never mount in application containers |

#### Recommended Additional Measures

1. **Use a Reverse Proxy** (Traefik, Caddy, or nginx proxy)
   - Terminate TLS at proxy level
   - Add rate limiting and WAF rules
   - Hide internal container topology

2. **Image Scanning**
   ```bash
   # Scan for vulnerabilities
   docker scout cves omeka-s-docker-php:latest
   ```

3. **Regular Updates**
   ```bash
   # Pull latest base images
   docker compose pull
   docker compose up -d --build
   ```

4. **Network Segmentation**
   - Database and PHP are on a separate backend network
   - Only nginx is exposed to the host via the frontend network

5. **Monitoring & Logging**
   - Ship logs to external aggregator (ELK, Loki)
   - Monitor container resource usage
   - Set up alerting for unusual activity

## Production SSL/TLS

This template does **not** handle SSL/TLS directly. For production deployments, place a reverse proxy in front of the stack. The reverse proxy terminates TLS and forwards plain HTTP to the nginx container on port 80.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Internet                              │
└──────────────────────┬──────────────────────────────────┘
                       │ HTTPS (443)
┌──────────────────────▼──────────────────────────────────┐
│              Reverse Proxy (Traefik/Caddy)              │
│  • TLS termination    • Rate limiting                   │
│  • WAF rules          • Load balancing                  │
└──────────────────────┬──────────────────────────────────┘
                       │ HTTP (80) — internal
┌──────────────────────▼──────────────────────────────────┐
│                 Omeka S Stack                            │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐              │
│  │  nginx  │───▶│   php   │───▶│  mysql  │              │
│  └─────────┘    └─────────┘    └─────────┘              │
│  (frontend)     (backend only)  (backend only)           │
└─────────────────────────────────────────────────────────┘
```

### Option A: Caddy (automatic HTTPS)

Caddy obtains and renews certificates automatically from Let's Encrypt.

Create a `Caddyfile` alongside the stack:

```
omeka.example.edu {
    reverse_proxy localhost:80
}
```

Then run Caddy:

```bash
caddy run
```

### Option B: Traefik (Docker-native)

Add labels to the `web` service in a `docker-compose.override.yml`:

```yaml
services:
  web:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.omeka.rule=Host(`omeka.example.edu`)"
      - "traefik.http.routers.omeka.tls.certresolver=letsencrypt"
```

### Option C: Standalone nginx reverse proxy

Install nginx on the host and create a site config:

```nginx
server {
    listen 443 ssl http2;
    server_name omeka.example.edu;

    ssl_certificate     /etc/letsencrypt/live/omeka.example.edu/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/omeka.example.edu/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name omeka.example.edu;
    return 301 https://$host$request_uri;
}
```

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

## License

MIT License
