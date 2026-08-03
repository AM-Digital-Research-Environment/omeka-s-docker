# Immutable Omeka code and storage migration

> **Status:** implemented 2026-07-31. Existing deployments that still have the
> legacy `omeka_files:/var/www/html` volume must run the migration below once.

## Architecture

The container image, not a volume, is now authoritative for Omeka core,
modules, themes, dependencies, and public assets. PHP and nginx are separate
targets in the same Dockerfile and receive identical build arguments. The
nginx target copies `/var/www/html` from the PHP runtime target, preventing
static assets from drifting from executable PHP code.

Only runtime state is writable:

| Path | Storage | Access |
|---|---|---|
| `/var/www/html/files` | `omeka_media` volume | PHP read/write; nginx read-only |
| `/var/www/html/logs` | `omeka_logs` volume | PHP read/write |
| `/var/www/html/config/local.config.php` | host file | PHP read-only |
| `/var/www/html/config/database.ini` | symlink to `/run/omeka/database.ini` | regenerated with mode `0600` on tmpfs |
| `/tmp`, `/run/omeka`, `/run/php-fpm`, `/var/www/.cache` | tmpfs | PHP read/write |
| `/var/lib/php-sessions` | `php_sessions` volume | PHP read/write |
| everything else under `/var/www/html` | image layer | read-only |

The PHP root filesystem is read-only. A marker at
`files/.immutable-layout-v1` distinguishes migrated media storage from an
accidentally empty volume. If Omeka is already installed but that marker is
missing, startup fails instead of silently serving a site without its media.

## One-time migration

Schedule a maintenance window and update this repository checkout first. The
migration script performs a backup and a read-only preflight before stopping
services:

```bash
bash scripts/migrate-immutable-storage.sh
```

The preflight builds the new PHP/nginx images and compares the deployed core,
module, and theme names and versions with the image. Any mismatch aborts before
the running stack is touched.

If a legacy extension cannot be reproduced from a release manifest, explicitly
adopt the exact deployed source into the image build context:

```bash
bash scripts/migrate-immutable-storage.sh --adopt-code
```

This copies legacy modules and themes into `_docker/local-modules/` and
`_docker/local-themes/`, then repeats the same exact-version preflight. Review
and commit that adopted source, or replace it with pinned upstream entries in
`_docker/extra-modules.txt` and `_docker/extra-themes.txt` later.

On confirmation, the script:

1. Keeps a mandatory backup under `backups/pre-immutable-*`.
2. Preserves legacy `config/local.config.php` as a read-only host config.
3. Stops services and copies only `files/` and `logs/` to dedicated volumes.
4. Verifies the media file count and writes the immutable-layout marker.
5. Starts the new stack and checks DB/PHP/nginx health and code immutability.

The old `<project>_omeka_files` volume is deliberately never deleted. Keep it
until the public site, admin, representative media, modules, themes, and IIIF
have been verified and a new-format backup has been restored in staging.

## Updates and rollback

Code changes now use image rebuilds:

```bash
# Add pinned build inputs and deploy matching PHP/nginx images
bash scripts/install-module.sh gh:owner/repository v1.2.3
bash scripts/install-theme.sh gh:owner/theme 0123456789abcdef

# Rebuild after editing manifests or local source
bash scripts/rebuild-code.sh

# Refresh floating refs (less reproducible; pin tags/commits where possible)
bash scripts/update-module.sh
```

An image rollback restores application code but cannot undo a database schema
migration. Back up first, deploy and test new code, then apply core/module DB
migrations as a separate decision.

## Regression coverage

CI boots module set A, writes database and media probes, performs a destructive
backup/restore round trip, rebuilds module set A+B on the same volumes, and
asserts that:

- the added module appears in both PHP and nginx;
- PHP/nginx contain byte-identical module source;
- the database and media probes survive;
- application code and nginx media remain non-writable.
