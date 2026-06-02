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
│   ├── default-modules.txt     # Modules downloaded during image build
│   └── vocabularies/           # Custom RDF vocabularies (auto-imported on first run)
├── nginx.conf                  # Nginx web server configuration
├── nginx-http-settings.conf    # Nginx HTTP-level settings (gzip, rate limiting)
├── nginx-security-headers.conf # Nginx security headers snippet
├── uploads.ini                 # PHP upload settings
├── .env.example                # Environment variables template
├── docs/
│   ├── COMMANDS.md             # Docker commands quick reference
│   ├── OMEKA_CLI.md            # omeka-s-cli usage and common workflows
│   ├── PRODUCTION.md           # Production deploy: reverse proxy, TLS, firewall, hardening
│   ├── BACKUP_RESTORE.md       # Backup, restore, and migration guide
│   └── DB_TUNING.md            # MySQL tuning parameter reference
├── scripts/
│   ├── backup.sh               # Backup database, files, and config
│   ├── restore.sh              # Restore from backup (migration)
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
| **typesense** _(optional)_ | typesense/typesense:27.1 | 8108 (internal) | Search backend for the DRESearch module — only runs under the `search` profile |

> The **typesense** service is entirely optional. The stack runs normally without it; it is excluded from `docker compose up` unless you opt in with `--profile search` (see [Search Backend](#search-backend-optional)).

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
docker compose exec php omeka-s-cli module:download ModuleName
docker compose exec php omeka-s-cli module:install ModuleName
```

See [docs/OMEKA_CLI.md](docs/OMEKA_CLI.md) for a fuller walk-through of common CLI workflows (modules, users, vocabularies, resource templates, settings).

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
| `SERVER_NAME` | No | `_` | Public hostname for nginx `server_name` (e.g. `omeka.example.edu`). Default `_` is a catch-all, safe when behind a trusted reverse proxy. |
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
| **CustomVocab** | Create custom controlled vocabularies |
| **DataCleaning** | Batch clean and normalize data |
| **EasyAdmin** | Administration dashboard and tools |
| **FacetedBrowse** | Create faceted search pages |
| **FileSideload** | Import files from server directory |
| **Hierarchy** | Organize items and item sets hierarchically |
| **IframeEmbed** | Embed iframes in page blocks |
| **ItemCarouselBlock** | Display items in a carousel block |
| **Log** | PSR-3 logger for Omeka S |
| **Mapping** | Add geographic locations to items |
| **NumericDataTypes** | Support for numeric and date values |
| **ResourceVisualizations** | Visualize resource relationships |

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

## Custom Vocabularies

In addition to the built-in vocabularies (Dublin Core, Dublin Core Type, Bibliographic Ontology, Friend of a Friend), the following RDF vocabularies are automatically imported on first run:

| Vocabulary | Prefix | Description |
|-----------|--------|-------------|
| **FRAPO** | `frapo` | Funding, Research Administration and Projects Ontology |
| **FaBiO** | `fabio` | FRBR-aligned Bibliographic Ontology |
| **WGS84 Geo** | `geo` | Latitude, longitude, altitude positioning |
| **MARC Relators** | `marcrel` | Library of Congress agent role terms |
| **DRE** | `dre` | Digital Research Environment custom vocabulary |

The ontology files and import script are in `_docker/vocabularies/`. To add more vocabularies, add their OWL files to that directory and register them in `_docker/vocabularies/import-vocabularies.php`.

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

## Search Backend (Optional)

The [DRESearch](https://github.com/AM-Digital-Research-Environment/DRESearch) module adds a faceted, [Typesense](https://typesense.org/)-backed search. **It is completely optional** — this template runs fine without it, and the `typesense` service stays out of the way unless you explicitly enable it. Keeping it off costs nothing and keeps the stack reusable for instances that don't need search.

### Enabling it

1. Set a strong, random API key in `.env` (this single key is shared by the Typesense server and the module):
   ```bash
   # In .env — generate one with:  openssl rand -hex 24
   TYPESENSE_API_KEY=your-long-random-string
   ```
2. Start (or recreate) the stack with the `search` profile, which adds the `typesense` service and injects the `TYPESENSE_*` settings into the `php` container:
   ```bash
   docker compose --profile search up -d
   ```
3. Install and activate the module, then point it at Typesense (it auto-reads the env vars, so its admin settings can be left blank):
   ```bash
   bash scripts/install-module.sh DRESearch
   ```

To run **without** search again, just start normally — `docker compose up -d` omits the profile and the `typesense` service never starts. Leaving `TYPESENSE_API_KEY` unset (or the module unconfigured) makes the module no-op gracefully.

### Security

The Typesense setup is designed not to widen the server's attack surface:

- **Never exposed to the host or internet.** The service publishes **no ports** — it is reachable only on the internal `backend` Docker network, server-side from `php`. Its admin API key therefore stays inside the same trust boundary as MySQL.
- **API key required.** Starting the `search` profile without `TYPESENSE_API_KEY` set makes Typesense exit immediately (`API key is not specified`) rather than run open. The key lives only in `.env` (gitignored).
- **Hardened like the rest of the stack:** `cap_drop: ALL`, `no-new-privileges`, a read-only root filesystem, browser CORS disabled, and CPU/memory limits (0.5 CPU / 512M) so it can't starve the host.
- **Nothing secret to back up.** The index in the `typesense_data` volume is rebuildable from MySQL, so it is excluded from backups.

## Bulk Imports

Use the `sideload/` directory for bulk file imports:

1. Place files in the `sideload/` directory
2. Activate the FileSideload module in the Omeka S admin panel (it is pre-installed)
3. In Omeka S admin, go to **Modules > FileSideload > Configure** and set the **Sideload directory** to `/var/www/html/sideload`
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

The container's nginx honors the `X-Forwarded-Proto` header, so any reverse proxy that forwards it (Caddy, Traefik, and standard nginx setups all do) will get correct `https://` URLs from Omeka in links, redirects, IIIF manifests, and emails — no extra Omeka configuration needed. Set `SERVER_NAME` in `.env` to the public hostname.

### Caddy (automatic HTTPS)

Install [Caddy](https://caddyserver.com/) on your host and create a Caddyfile:

```
omeka.example.edu {
    reverse_proxy 127.0.0.1:8080
}
```

Then update your `.env` so the container nginx no longer holds port 80 on the host: `NGINX_PORT=8080`, restart the stack with `docker compose up -d --force-recreate web`, and start Caddy. Certificates are obtained and renewed automatically.

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

First free port 80 on the host so the host nginx can bind it — set `NGINX_PORT=8080` in `.env` and run `docker compose up -d --force-recreate web`. The container nginx will then listen only on `127.0.0.1:8080`.

Install nginx on the host and create a site config:

```nginx
# HTTP → HTTPS redirect (also serves ACME HTTP-01 challenges)
server {
    listen 80;
    listen [::]:80;
    server_name omeka.example.edu;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS — terminates TLS and proxies to the Omeka container on :8080
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name omeka.example.edu;

    ssl_certificate     /etc/letsencrypt/live/omeka.example.edu/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/omeka.example.edu/privkey.pem;

    # Modern TLS (Mozilla intermediate)
    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache       shared:SSL:50m;
    ssl_session_timeout     1d;
    ssl_session_tickets     off;

    # Enable HSTS only after the cert pipeline is confirmed working
    # add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    # Match the container's upload limit (Omeka allows 100 MB)
    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
```

For a full production walk-through (firewall rules, cert provisioning paths, host-OS hardening, verification), see [docs/PRODUCTION.md](docs/PRODUCTION.md).

## Volumes

Data is persisted in Docker volumes:

| Volume | Purpose |
|--------|---------|
| `mysql_data` | MySQL database files |
| `omeka_files` | Omeka S installation and uploads |

## Backup & Migration

Backup and restore scripts are included for creating full snapshots and migrating to another server:

```bash
# Create a full backup (database + files + config)
bash scripts/backup.sh

# Restore from a backup
bash scripts/restore.sh backups/20260330-120000
```

The backup script stops containers during the process to guarantee data consistency, then restarts them automatically. See [docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md) for the full migration guide.

## License

MIT License
