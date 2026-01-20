# Omeka S Docker Template

A reusable Docker template for deploying Omeka S digital archive installations. This template provides a production-ready setup with automatic installation, optimized PHP configuration, and comprehensive module management scripts.

## Features

- **Automatic Installation**: Omeka S is automatically installed on first run
- **Pre-installed Modules**: Common modules included by default
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
├── docker-compose.ssl.yml      # SSL override for production
├── Dockerfile                  # PHP-FPM container configuration
├── nginx.conf                  # Nginx web server configuration (HTTP)
├── nginx-ssl.conf              # Nginx configuration with SSL/TLS
├── uploads.ini                 # PHP upload settings
├── docker-entrypoint.sh        # PHP container initialization & auto-install
├── .env.example                # Environment variables template
├── scripts/
│   ├── install-module.sh       # Install new modules
│   ├── update-module.sh        # Update existing modules
│   └── update-omeka.sh         # Update Omeka S core
├── ssl/                        # SSL certificates (gitignored)
└── sideload/                   # Bulk import directory
```

## Services Overview

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| **web** | nginx:1.28-alpine | 80 | Reverse proxy, static files |
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
OMEKA_VERSION=latest    # or specific version like 4.2.0
NGINX_PORT=80           # change if port 80 is in use

# SSL Configuration (for production)
DOMAIN_NAME=omeka.example.edu
NGINX_SSL_PORT=443
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
- SSL certificates should be configured for production (see below)

## Security Hardening (Built-in)

This template includes Docker security hardening by default in the main `docker-compose.yml`:

| Feature | Description |
|---------|-------------|
| **Resource Limits** | CPU and memory limits prevent DoS attacks |
| **no-new-privileges** | Prevents privilege escalation inside containers |
| **Dropped Capabilities** | Removes unnecessary Linux capabilities |
| **Read-only Filesystems** | nginx runs with read-only root filesystem |

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
   - Database should never be directly accessible
   - Use internal networks for inter-service communication

5. **Monitoring & Logging**
   - Ship logs to external aggregator (ELK, Loki)
   - Monitor container resource usage
   - Set up alerting for unusual activity

### Reverse Proxy Architecture

For production, consider placing Omeka S behind a dedicated reverse proxy:

```
┌─────────────────────────────────────────────────────────┐
│                    Internet                              │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│              Reverse Proxy (Traefik/Caddy)              │
│  • TLS termination    • Rate limiting                   │
│  • WAF rules          • Load balancing                  │
└──────────────────────┬──────────────────────────────────┘
                       │ Internal Network
┌──────────────────────▼──────────────────────────────────┐
│                 Omeka S Stack                            │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐              │
│  │  nginx  │───▶│   php   │───▶│  mysql  │              │
│  └─────────┘    └─────────┘    └─────────┘              │
│                                 (internal only)          │
└─────────────────────────────────────────────────────────┘
```

## Production SSL Deployment

For production deployments with SSL/TLS, use the provided SSL configuration with your organization's certificates.

### 1. Prepare SSL Certificates

Place your SSL certificate files in the `ssl/` directory:

```
ssl/
├── fullchain.pem    # Your certificate + intermediate chain
└── privkey.pem      # Your private key
```

> **Note**: The `ssl/` directory is gitignored to prevent accidental commits of private keys.

### 2. Configure Environment

Update your `.env` file with domain settings:

```bash
MYSQL_PASSWORD=your_secure_mysql_password
DOMAIN_NAME=omeka.youruniversity.edu
NGINX_SSL_PORT=443
```

### 3. Start with SSL

Use the SSL compose override file:

```bash
docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d
```

### SSL Configuration Details

The SSL configuration (`nginx-ssl.conf`) includes:

| Feature | Setting |
|---------|---------|
| **Protocols** | TLS 1.2, TLS 1.3 |
| **Ciphers** | Mozilla Modern configuration |
| **HSTS** | Enabled (2 years, includeSubDomains) |
| **HTTP Redirect** | Automatic redirect to HTTPS |
| **OCSP Stapling** | Enabled |

### Project Structure with SSL

```
.
├── docker-compose.yml          # Base configuration
├── docker-compose.ssl.yml      # SSL override (use with -f flag)
├── nginx.conf                  # HTTP-only nginx config
├── nginx-ssl.conf              # HTTPS nginx config
└── ssl/                        # SSL certificates (gitignored)
    ├── fullchain.pem
    └── privkey.pem
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
