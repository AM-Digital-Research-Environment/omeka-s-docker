# Backup, restore, and server migration

## Backup contents

Current backups use `omeka-docker-backup-v2` and declare their layout in
`BACKUP_FORMAT`.

| Artifact | Contents |
|---|---|
| `omeka_db.sql` | Consistent MySQL dump |
| `omeka_media.tar.gz` | Uploaded files and derivatives from `omeka_media` |
| `omeka_logs.tar.gz` | Application logs, when the volume exists |
| `local.config.php` | Exact read-only deployment configuration |
| `images.json` | Running image provenance, when containers exist |
| `typesense_data.tar.gz` | Optional, rebuildable Typesense index |
| `sideload.tar.gz` | Optional sideload directory |
| `.env` | Compose configuration and secrets |
| `SHA256SUMS` | Integrity checks for every included artifact |

### What is deliberately not included

| Not backed up | Why |
|---|---|
| Omeka, module, and theme code | It comes from the image. Your module and theme lists in Git are the record of what to build |
| Login sessions | Nothing worth keeping; people simply log in again |
| `dre_visualizations_data` (AMIRA only) | Regenerated from the database by the admin "Regenerate" action |

This is why the repository revision matters as much as the backup: the backup
holds your data and settings, the repository holds the recipe for the code. Keep
both.

### Backups from before the storage migration

If the deployment still has the old whole-application-folder volume, the script
notices, records `layout=legacy`, and writes `omeka_files.tar.gz` instead.
Restore reads both layouts, but from a legacy archive it extracts only `files/`,
the logs, and `local.config.php`. Old code is never restored into the current
runtime — that comes from the image.

## Create a backup

```bash
# Default: backups/<timestamp>/
bash scripts/backup.sh

# Explicit destination
bash scripts/backup.sh /path/to/backup-dir
```

The application stays online. MySQL uses `--single-transaction`, and Docker
volumes are mounted read-only for archiving. Do not install/upgrade modules or
apply core schema migrations concurrently: DDL is outside the database
snapshot guarantee. Media and SQL are also separate snapshot boundaries, so
retain multiple generations.

The directory is mode `0700`; `.env` and `local.config.php` are mode `0600`.
Checksums detect corruption, not hostile replacement. Encrypt backups and keep
at least one tested copy off the Docker host.

## Restore

```bash
bash scripts/restore.sh backups/20260731-120000

# Deliberate non-interactive overwrite (automation/CI)
bash scripts/restore.sh --force backups/20260731-120000
```

Restore verifies `SHA256SUMS` before changing state, warns when any existing
media/legacy/MySQL volume would be overwritten, restores the deployment config
as `_docker/restored-local.config.php`, recreates the database, and starts the
stack. The restored media volume must contain the immutable-layout marker.

Restore is destructive and not transactional. If interrupted, correct the
underlying problem and repeat it from the same verified backup.

## Move to another server

1. Create and retain a backup on the old host.
2. Clone the same repository revision on the new host.
3. Transfer the whole backup directory with `rsync` or `scp`.
4. Run `bash scripts/restore.sh <backup-directory>`.
5. Wait for `docker compose ps` to report healthy services.
6. Verify admin login, representative media, modules/themes, IIIF, and search.
7. Change DNS only after verification.

The repository revision and build manifests matter: persistent backups contain
data and configuration, while code comes from the image build.

## Retention example

```cron
0 3 * * * cd /path/to/omeka-s-docker && bash scripts/backup.sh && find backups/ -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
```

Test restores periodically in a separate Compose project. Keep the prior
backup until the restored application has been exercised, not merely started.
