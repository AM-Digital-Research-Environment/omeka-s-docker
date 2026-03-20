# Omeka S Docker Template

A reusable Docker template for deploying Omeka S digital archive installations. This template provides a production-ready setup with automatic installation, optimized PHP configuration, and comprehensive module management scripts.

## Features

- **Automatic Installation**: Omeka S is automatically installed on first run
- **Pre-installed Modules**: Common modules included by default
- **Optimized PHP 8.4**: Pre-configured with OPcache, APCu, and Imagick
- **Non-root Execution**: PHP-FPM workers run as www-data via pool configuration
- **Network Isolation**: Separate frontend/backend networks isolate PHP and MySQL
- **Production-Ready Nginx**: Gzip compression, security headers, static file caching
- **Module Management**: Scripts for installing and updating modules
- **Health Checks**: All services include Docker health checks
- **Optional Automatic HTTPS**: Built-in Caddy reverse proxy with Let's Encrypt

## Prerequisites

- Docker and Docker Compose v2
- For HTTPS: a domain name with a DNS A record pointing to your server

## Project Structure

```
.
├── docker-compose.yml          # Main service orchestration
├── Dockerfile                  # PHP-FPM container build
├── nginx.conf                  # Nginx web server configuration
├── nginx-http-settings.conf    # Nginx HTTP-level settings (gzip, rate limiting)
├── nginx-security-headers.conf # Nginx security headers snippet
├── uploads.ini                 # PHP upload settings
├── docker-entrypoint.sh        # PHP container initialization & auto-install
├── ensure-composer.sh          # On-demand Composer installer
├── .env.example                # Environment variables template
├── COMMANDS.md                 # Docker commands quick reference
├── docs/
│   └── DB_TUNING.md            # MySQL tuning parameter reference
├── scripts/
│   ├── install-module.sh       # Install new modules
│   ├── install-theme.sh        # Install themes from GitHub
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

### One-Line Setup (Fresh Linux Server)

For a fully automated setup on a clean Linux VM, see **[am-omeka-s-docker-bootstrap](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap)**. A single `curl` command installs Docker, clones this project, configures everything (including optional HTTPS with Caddy), and launches the services.

### Manual Setup

If you prefer to do things step by step, or already have Docker installed:

#### 1. Clone and Configure

```bash
# Clone this template
git clone https://github.com/AM-Digital-Research-Environment/omeka-s-docker.git my-omeka-site
cd my-omeka-site

# Create environment file
cp .env.example .env

# Edit .env with your secure password
nano .env
```

#### 2. Start Services

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

Create a `.env` file from `.env.example`. All supported variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MYSQL_PASSWORD` | Yes | - | MySQL password for the Omeka S database |
| `OMEKA_VERSION` | No | `4.2.0` | Omeka S version to install |
| `NGINX_PORT` | No | `80` | Host port for nginx (use `127.0.0.1:8080` with a reverse proxy) |
| `EXTRA_MODULES` | No | - | Comma-separated modules to auto-install (e.g. `EasyAdmin,CSSEditor`) |
| `EXTRA_THEMES` | No | - | Comma-separated themes to auto-install (e.g. `Cozy,Foundation`) |
| `ENABLE_IIIF` | No | `false` | Set to `true` to install IIIF modules (IiifServer, ImageServer, Mirador) |
| `PHP_PM_MAX_CHILDREN` | No | `10` | PHP-FPM max worker processes |
| `PHP_PM_START_SERVERS` | No | `3` | PHP-FPM workers started on boot |
| `PHP_PM_MIN_SPARE_SERVERS` | No | `2` | Minimum idle workers |
| `PHP_PM_MAX_SPARE_SERVERS` | No | `5` | Maximum idle workers |
| `PHP_PM_MAX_REQUESTS` | No | `500` | Requests before worker respawn (prevents memory leaks) |

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
| **Common** | Shared library required by many Daniel-KM modules |
| **CSVImport** | Import items from CSV files |
| **DataCleaning** | Batch clean and normalize data |
| **DspaceConnector** | Import items from DSpace repositories |
| **FacetedBrowse** | Create faceted search pages |
| **FileSideload** | Import files from server directory |
| **IframeEmbed** | Embed iframes in page blocks |
| **ItemCarouselBlock** | Display items in a carousel block |
| **Log** | PSR-3 logger for Omeka S (replaces default logging) |
| **Mapping** | Add geographic locations to items |
| **NumericDataTypes** | Support for numeric and date values |
| **ValueSuggest** | Auto-suggest values from controlled vocabularies |

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
- Cron, EasyAdmin, Reference


Run `./scripts/install-module.sh list` to see all available modules.

### Module Dependencies

Dependencies are **automatically installed** when you install a module that requires them. For example:

```bash
# This will automatically install Cron first, then EasyAdmin
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
| EasyAdmin | Cron |
| SearchSolr | AdvancedSearch |

Common and Log are pre-installed and available as dependencies for all modules above.

**Activation order in Omeka S admin:**
When activating modules with dependencies, always activate them in order:
1. Common and Log (pre-installed, activate first)
2. Other dependencies (Cron, AdvancedSearch, etc.)
3. The module you want to use (EasyAdmin, SearchSolr, etc.)

## IIIF Support

### IIIF Modules (Optional)

Set `ENABLE_IIIF=true` in your `.env` file to automatically install the following modules on first run:

| Module | Source | Purpose |
|--------|--------|---------|
| **IiifServer** | [GitHub](https://github.com/Daniel-KM/Omeka-S-module-IiifServer) | Serves IIIF Presentation and Image API responses |
| **ImageServer** | [GitHub](https://github.com/Daniel-KM/Omeka-S-module-ImageServer) | Generates tiles and serves images via IIIF Image API |
| **Mirador** | [GitLab](https://gitlab.com/Daniel-KM/Omeka-S-module-Mirador) | Embeds the Mirador IIIF viewer for item display |

Dependencies (Common) are installed automatically. The image includes `libvips` and the `exif` PHP extension, which are used by ImageServer for efficient image processing.

```bash
# Enable in .env
ENABLE_IIIF=true

# Then start or recreate containers
docker compose up -d
```

After installation, activate the modules in the Omeka S admin panel in this order:
1. Common and Log (pre-installed, activate first if not already active)
2. IiifServer
3. ImageServer
4. Mirador

## Bulk Imports

Use the `sideload/` directory for bulk file imports:

1. Place files in the `sideload/` directory
2. Activate the FileSideload module in the Omeka S admin panel (it is pre-installed)
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

### Built-in: Caddy (automatic HTTPS)

The [bootstrap script](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap) can install and configure [Caddy](https://caddyserver.com/) automatically. When enabled during setup:

- Caddy runs on the host as a systemd service
- Nginx binds to `127.0.0.1:8080` (not exposed externally)
- Caddy handles ports 80/443 and obtains Let's Encrypt certificates automatically
- Certificates are renewed automatically — zero maintenance

```
┌─────────────────────────────────────────────────────────┐
│                    Internet                              │
└──────────────────────┬──────────────────────────────────┘
                       │ HTTPS (443)
┌──────────────────────▼──────────────────────────────────┐
│                 Caddy (host)                             │
│  • Auto TLS (Let's Encrypt)  • HTTP→HTTPS redirect      │
│  • Certificate renewal       • Reverse proxy             │
└──────────────────────┬──────────────────────────────────┘
                       │ HTTP (127.0.0.1:8080) — localhost
┌──────────────────────▼──────────────────────────────────┐
│                 Omeka S Stack (Docker)                    │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐              │
│  │  nginx  │───▶│   php   │───▶│  mysql  │              │
│  └─────────┘    └─────────┘    └─────────┘              │
│  (frontend)     (backend only)  (backend only)           │
└─────────────────────────────────────────────────────────┘
```

The Caddyfile is written to `/etc/caddy/Caddyfile` and can be edited any time:

```bash
sudo nano /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

If you skipped HTTPS during initial setup, you can add it later by installing Caddy manually and creating a Caddyfile:

```
omeka.example.edu {
    reverse_proxy 127.0.0.1:8080
}
```

Then update your `.env` to bind nginx to localhost: `NGINX_PORT=127.0.0.1:8080`, restart the stack with `docker compose up -d`, and start Caddy.

### Alternative: Traefik (Docker-native)

Add labels to the `web` service in a `docker-compose.override.yml`:

```yaml
services:
  web:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.omeka.rule=Host(`omeka.example.edu`)"
      - "traefik.http.routers.omeka.tls.certresolver=letsencrypt"
```

### Alternative: Standalone nginx reverse proxy

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
docker run --rm -v omeka-s-docker_omeka_files:/data -v $(pwd):/backup alpine tar czf /backup/omeka-files.tar.gz -C /data .
```

## License

MIT License
