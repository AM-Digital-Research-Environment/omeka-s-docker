# Omeka S Docker Template

A reusable Docker template for deploying Omeka S digital archive installations. This template provides a production-ready setup with automatic installation, optimized PHP configuration, and module management via [omeka-s-cli](https://github.com/GhentCDH/Omeka-S-Cli).

## Features

- **Automatic Installation**: Omeka S is downloaded during build and installed on first run
- **Pre-installed Modules**: Common modules baked into the image
- **Optimized PHP 8.4**: Pre-configured with OPcache, APCu, and Imagick
- **Non-root Execution**: PHP-FPM workers run as www-data
- **Network Isolation**: Separate frontend/backend networks isolate PHP and MySQL
- **Production-Ready Nginx**: Gzip compression, security headers, static file caching
- **Health Checks**: All services include Docker health checks

## Prerequisites

- Docker and Docker Compose v2

## Project Structure

```
.
├── docker-compose.yml          # Main service orchestration
├── Dockerfile                  # PHP-FPM container build (multi-stage)
├── docker-entrypoint.sh        # PHP container initialization & auto-install
├── _docker/
│   └── default-modules.txt     # Modules downloaded during image build
├── nginx.conf                  # Nginx web server configuration
├── nginx-http-settings.conf    # Nginx HTTP-level settings (gzip, rate limiting)
├── nginx-security-headers.conf # Nginx security headers snippet
├── uploads.ini                 # PHP upload settings
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

### 1. Clone and Configure

```bash
# Clone this template
git clone https://github.com/AM-Digital-Research-Environment/omeka-s-docker.git my-omeka-site
cd my-omeka-site

# Create environment file
cp .env.example .env

# Edit .env with your settings (at minimum, set MYSQL_PASSWORD)
nano .env
```

### 2. Start Services

```bash
# Build and start all services (Omeka S will auto-install on first run)
docker compose up -d --build

# Watch the installation progress
docker compose logs -f php
```

### 3. Access Omeka S

1. Wait for all services to show as "healthy":
   ```bash
   docker compose ps
   ```

2. Open your browser to `http://localhost` (or your server IP)

3. If you set `OMEKA_ADMIN_EMAIL`, `OMEKA_ADMIN_USERNAME`, and `OMEKA_ADMIN_PASSWORD` in `.env`, an admin account is created automatically. Otherwise, complete the web installation wizard.

### 4. Install Additional Modules (Optional)

Many modules are pre-installed (see below). To add more at runtime, set `EXTRA_MODULES` in your `.env`:

```bash
# In .env
EXTRA_MODULES=DspaceConnector,ValueSuggest,CSSEditor

# Then restart
docker compose down && docker compose up -d
```

You can also use the `omeka-s-cli` inside the container:

```bash
docker compose exec php omeka-s-cli module:download --base-path /var/www/html ModuleName
docker compose exec php omeka-s-cli module:install --base-path /var/www/html ModuleName
```

## Environment Variables

Create a `.env` file from `.env.example`. All supported variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `MYSQL_PASSWORD` | Yes | - | MySQL password for the Omeka S database |
| `OMEKA_VERSION` | No | `4.2.0` | Omeka S version to install |
| `OMEKA_ADMIN_EMAIL` | No | - | Admin email (skips web wizard if all three admin vars are set) |
| `OMEKA_ADMIN_USERNAME` | No | - | Admin username |
| `OMEKA_ADMIN_PASSWORD` | No | - | Admin password |
| `OMEKA_TZ` | No | `UTC` | Timezone (e.g. `Europe/Berlin`) |
| `OMEKA_LOCALE` | No | - | Locale (e.g. `en_US`) |
| `OMEKA_TITLE` | No | - | Site title |
| `NGINX_PORT` | No | `80` | Host port for nginx (use `127.0.0.1:8080` with a reverse proxy) |
| `EXTRA_MODULES` | No | - | Comma-separated modules to install at runtime (e.g. `DspaceConnector,CSSEditor`) |
| `EXTRA_THEMES` | No | - | Comma-separated themes to install at runtime (e.g. `Cozy,Foundation`) |
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

## Module Management

### Pre-installed Modules

The following modules are downloaded during the Docker image build and automatically installed on first run. They are defined in `_docker/default-modules.txt`.

| Module | Purpose |
|--------|---------|
| **ActivityLog** | Track resource activity |
| **Common** | Shared library required by many Daniel-KM modules |
| **Cron** | Schedule background tasks |
| **CSVImport** | Import items from CSV files |
| **DataCleaning** | Batch clean and normalize data |
| **EasyAdmin** | Administration dashboard and tools |
| **FacetedBrowse** | Create faceted search pages |
| **FileSideload** | Import files from server directory |
| **IframeEmbed** | Embed iframes in page blocks |
| **ItemCarouselBlock** | Display items in a carousel block |
| **Log** | PSR-3 logger for Omeka S |
| **Mapping** | Add geographic locations to items |
| **NumericDataTypes** | Support for numeric and date values |

These modules are ready to activate in the Omeka S admin panel after installation.

**Activation order**: When activating modules with dependencies, activate them in order:
1. Common and Log first
2. Cron
3. EasyAdmin and other modules

### Adding Modules at Runtime

Use the `EXTRA_MODULES` environment variable in `.env` to install additional modules when the container starts:

```bash
EXTRA_MODULES=DspaceConnector,ValueSuggest,CSSEditor
```

The entrypoint accepts module names from the official `omeka-s-modules` GitHub org, or full `gh:` references for third-party modules:

```bash
EXTRA_MODULES=ValueSuggest,gh:Daniel-KM/Omeka-S-module-AdvancedSearch
```

### Adding Modules to the Image

To permanently add a module to the image (so it's always available), add it to `_docker/default-modules.txt` and rebuild:

```bash
# Edit the file
echo "ValueSuggest" >> _docker/default-modules.txt

# Rebuild
docker compose up -d --build
```

## IIIF Support (Optional)

Set `ENABLE_IIIF=true` in your `.env` file to automatically install IiifServer, ImageServer, and Mirador on first run:

```bash
# In .env
ENABLE_IIIF=true

# Then start or recreate containers
docker compose up -d
```

These modules depend on Common, which is pre-installed. After startup, activate modules in this order in the Omeka S admin panel:
1. Common (if not already active)
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

### Caddy (automatic HTTPS)

Install [Caddy](https://caddyserver.com/) on your host and create a Caddyfile:

```
omeka.example.edu {
    reverse_proxy 127.0.0.1:8080
}
```

Then update your `.env` to bind nginx to localhost: `NGINX_PORT=127.0.0.1:8080`, restart the stack with `docker compose up -d`, and start Caddy. Certificates are obtained and renewed automatically.

### Traefik (Docker-native)

Add labels to the `web` service in a `docker-compose.override.yml`:

```yaml
services:
  web:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.omeka.rule=Host(`omeka.example.edu`)"
      - "traefik.http.routers.omeka.tls.certresolver=letsencrypt"
```

### Standalone nginx reverse proxy

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
