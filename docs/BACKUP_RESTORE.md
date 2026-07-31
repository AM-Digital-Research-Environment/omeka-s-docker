# Backup & Restore / Server Migration

This guide explains how to back up a running Omeka S Docker instance and restore it — either on the same server or on a new one.

## What gets backed up

| File | Contents |
|---|---|
| `omeka_db.sql` | Full MySQL database dump (items, metadata, users, settings) |
| `omeka_files.tar.gz` | Omeka `files/` volume (uploaded media, modules, themes) |
| `typesense_data.tar.gz` | Typesense index (only when the volume exists; rebuildable from MySQL) |
| `sideload.tar.gz` | Sideload directory (only if non-empty) |
| `.env` | Environment variables (database password, admin credentials) |
| `SHA256SUMS` | Integrity checksums for every artifact in the backup |

## Backup

The backup script is **zero-downtime**. It takes an InnoDB
`--single-transaction` database snapshot and mounts Docker volumes read-only
while archiving them; application containers remain available.

```bash
# Default: creates backups/<timestamp>/ in the project directory
bash scripts/backup.sh

# Or specify a custom path
bash scripts/backup.sh /path/to/backup-dir
```

Do not install or update modules, update Omeka core, or run other schema-changing
operations during a backup. `--single-transaction` protects the dump from normal
reads and writes, but not concurrent DDL. Uploaded Omeka media are effectively
write-once; a file created during the archive may land just outside the database
snapshot boundary, so retain multiple generations of backups.

The backup directory is created with mode `0700`, `.env` with `0600`, and an
integrity manifest is generated. Checksums detect corruption, not malicious
replacement: encrypt backups and store copies away from the Docker host.

## Restore (same server)

```bash
bash scripts/restore.sh backups/20260330-120000
```

> **Warning**: restoring on a server with existing data will **overwrite** the current database and files. You will be prompted for confirmation.

The warning is based on whether the Omeka/MySQL volumes exist, even when the
containers are stopped. For a deliberate non-interactive restore (for example,
in CI), pass `--force`:

```bash
bash scripts/restore.sh --force backups/20260330-120000
```

When `SHA256SUMS` exists, restore verifies it before changing the target. Legacy
backups without a manifest remain restorable but produce a warning.

## Migrate to a new server

### 1. Back up on the old server

```bash
bash scripts/backup.sh
```

### 2. Set up the new server

```bash
# Install Docker and Docker Compose, then:
git clone https://github.com/AM-Digital-Research-Environment/omeka-s-docker.git ~/omeka-s-docker
cd ~/omeka-s-docker
```

### 3. Transfer the backup

```bash
# From the old server
scp -r backups/20260330-120000 user@new-server:~/omeka-s-docker/backups/
```

Or use `rsync` for large backups (resumable):

```bash
rsync -avP backups/20260330-120000 user@new-server:~/omeka-s-docker/backups/
```

### 4. Restore on the new server

```bash
cd ~/omeka-s-docker
bash scripts/restore.sh backups/20260330-120000
```

The restore script will:

1. Validate required files and verify `SHA256SUMS` when present
2. Copy `.env` from the backup if none exists
3. Warn before overwriting any existing Omeka/MySQL volumes
4. Restore `omeka_files`, optional Typesense data, and optional sideload files
5. Start the database, recreate the configured database, and import the dump
6. Start all services (including the search profile when Typesense was restored)

### 5. Verify

```bash
# Check all services are healthy
docker compose ps

# Check the site is accessible
curl -I http://localhost
```

### 6. Update DNS

If your Omeka S instance uses a domain name, point it to the new server's IP once you've confirmed everything works.

## Tips

- **Schedule regular backups** by adding a cron job:
  ```bash
  # Daily backup at 3 AM, keep last 7 days
  0 3 * * * cd /path/to/omeka-s-docker && bash scripts/backup.sh && find backups/ -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
  ```
- **Test your backups** periodically by restoring to a staging environment.
- The `.env` file contains credentials. Encrypt backups in transit and at rest,
  restrict access, and keep at least one tested copy off-host.
- Restore is destructive and not transactional. If it is interrupted, fix the
  underlying problem and restart it from a verified backup; keep the previous
  backup until the restored site has been tested.
