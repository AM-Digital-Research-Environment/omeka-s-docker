# Command reference

Quick reference for running an Omeka S site built from this template.

## Which command for which job

| I want to… | Run |
|-----------|-----|
| See if everything is working | `docker compose ps` |
| See what went wrong | `docker compose logs -f php` |
| Add a module or theme to the running site | The admin panel (Easy Admin), or `docker compose exec php omeka-s-cli module:download …` |
| Turn a module on, or apply its database changes | `docker compose exec php omeka-s-cli module:install …` |
| Move to a new Omeka S version | `bash scripts/update-omeka.sh` |
| Change what a *fresh* build starts with | `bash scripts/install-module.sh …` or `install-theme.sh …` |
| Back up | `bash scripts/backup.sh` |
| Restore, or move to a new server | `bash scripts/restore.sh <backup-dir>` |

The rule of thumb: **Omeka itself changes by rebuilding; everything else —
modules, themes, users, settings — changes on the running site.**

The `scripts/` helpers deal with what a build produces. They do not change the
modules and themes a running site has, because the site owns those (see
[IMMUTABLE_CODE.md](IMMUTABLE_CODE.md)). The exception is a site using
`compose.immutable.yml`, where the image is the only source of modules and
themes and the scripts are the only way to change them.

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

# Why is a service unhealthy?
docker inspect --format='{{json .State.Health}}' "$(docker compose ps -q php)"
```

## Rebuilding the image

Omeka itself, PHP, and the web server are part of the image, so changing any of
them means a rebuild. This builds both the PHP and web images together and swaps
the containers, keeping your database, files, modules, and themes.

```bash
# The usual case
bash scripts/rebuild-code.sh

# Also re-download modules that track a branch rather than a fixed version
bash scripts/rebuild-code.sh --refresh

# Also fetch newer base images (PHP, nginx) first
bash scripts/rebuild-code.sh --pull

# Build only — don't touch the running site
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

## ⚠️ Starting completely over

```bash
# Deletes the database, all uploaded files, everything. There is no undo.
docker compose down -v

docker compose up -d
```

Take a backup first (`bash scripts/backup.sh`) unless you are certain there is
nothing you want.

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

## Keeping things up to date

```bash
# Newer database and search engine images
docker compose pull

# Newer PHP and web server base images, then rebuild
bash scripts/rebuild-code.sh --pull
```

## Backup & Restore

```bash
# Everything: database, files, sideload folder, settings.
# The site stays up. Just don't install or upgrade a module while it runs.
bash scripts/backup.sh

# Somewhere other than backups/
bash scripts/backup.sh /tmp/omeka-backup

# Restore (asks for confirmation before overwriting anything)
bash scripts/restore.sh backups/20260330-120000

# Restore without asking — destructive, for automation only
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

## Settings

```bash
# See exactly what your .env resolves to
docker compose config

# Try a setting without editing .env
NGINX_PORT=9000 docker compose up -d
```

Settings that become part of the image — `OMEKA_VERSION`, `EXTRA_MODULES`,
`EXTRA_THEMES`, `ENABLE_IIIF`, and the `*_FILE` variants — need a rebuild, not a
restart:

```bash
bash scripts/rebuild-code.sh
```

All but `OMEKA_VERSION` decide what a site starts life with, so on a site that
is already running they change the image without changing the site. Only
`OMEKA_VERSION` takes effect on an existing site — and `scripts/update-omeka.sh`
is the way to change that one.

## Optional services and deployment folders

```bash
# Start with the search engine included
docker compose --profile search up -d

# Make that permanent — in .env:
#   COMPOSE_PROFILES=search

# Run a deployment folder's extra services — in .env:
#   COMPOSE_FILE=docker-compose.yml:compose.amira.yml

# Check what a deployment folder actually adds
docker compose config --services
```

Once `COMPOSE_FILE` and `COMPOSE_PROFILES` are in `.env`, every command on this
page picks them up automatically. Nothing else changes.

## Modules

On the running site — the same thing the Easy Admin module does in the browser:

```bash
# What is installed, and what has an update?
docker compose exec php omeka-s-cli module:list

# Find, fetch, and turn on a module
docker compose exec php omeka-s-cli module:search facet
docker compose exec php omeka-s-cli module:download CSVImport
docker compose exec php omeka-s-cli module:install CSVImport

# Update one, then apply its database changes
docker compose exec php omeka-s-cli module:update CSVImport
docker compose exec php omeka-s-cli module:upgrade CSVImport

# Remove it
docker compose exec php omeka-s-cli module:uninstall CSVImport
docker compose exec php omeka-s-cli module:delete CSVImport
```

To change what a *fresh* build starts with — and on sites using
`compose.immutable.yml`, where this is the only way:

```bash
# What is on the list so far?
bash scripts/install-module.sh list

# Add one from Omeka's registry, or from GitHub at a fixed version
bash scripts/install-module.sh CSVImport
bash scripts/install-module.sh gh:owner/repository v1.2.3

# After editing a version in _docker/extra-modules.txt
bash scripts/rebuild-code.sh

# Re-download modules that track a branch instead of a fixed version
bash scripts/update-module.sh
```

Updating Omeka S itself:

```bash
bash scripts/update-omeka.sh --dry-run   # see what would change
bash scripts/update-omeka.sh             # newest release
bash scripts/update-omeka.sh 4.2.1       # a specific release
```

## Themes

On the running site:

```bash
docker compose exec php omeka-s-cli theme:search CenterRow   # find it, and its latest version
docker compose exec php omeka-s-cli theme:download centerrow
docker compose exec php omeka-s-cli theme:list               # what the site has now
```

Then pick it for a site under **Sites > (your site) > Theme** in the admin panel.

To change what a fresh build starts with:

```bash
bash scripts/install-theme.sh list
bash scripts/install-theme.sh gh:omeka-s-themes/CenterRow v1.8.0

# Or edit _docker/extra-themes.txt yourself, then
bash scripts/rebuild-code.sh
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
# Why is a service unhealthy?
docker inspect --format='{{json .State.Health}}' "$(docker compose ps -q php)"

# Check who owns the uploaded files, and fix their permissions if needed
docker compose exec php id
docker compose exec php ls -ld /var/www/html/files
docker compose exec php chmod -R u=rwX,go=rX /var/www/html/files

# Clear caches by recreating the containers (your code and data are untouched)
docker compose up -d --force-recreate php web

# Can the database be reached?
docker compose exec db mysqladmin ping -u omeka -p
```

Things that will *not* work, by design:

```bash
docker compose exec php nano /var/www/html/application/...   # Omeka's own code is read-only
docker compose exec php composer update                      # so are its libraries
```

Omeka itself, its libraries, and its configuration cannot be written to while
the site runs. Changing them is a rebuild — `bash scripts/update-omeka.sh`. The
module and theme folders *are* writable, so `module:download` and friends work
normally; see the [README](../README.md#how-this-template-works).

On a site using `compose.immutable.yml`, nothing under the application folder is
writable, so `module:download` and `theme:download` fail there too. That is the
design working, not a permissions problem — add the module to a list and rebuild
instead.

For a longer list of specific symptoms and their causes, see
[Troubleshooting in the README](../README.md#troubleshooting).
