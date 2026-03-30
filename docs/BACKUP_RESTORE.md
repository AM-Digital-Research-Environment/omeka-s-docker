# Backup & Restore / Server Migration

This guide explains how to back up a running Omeka S Docker instance and restore it — either on the same server or on a new one.

## What gets backed up

| File | Contents |
|---|---|
| `omeka_db.sql` | Full MySQL database dump (items, metadata, users, settings) |
| `omeka_files.tar.gz` | Omeka `files/` volume (uploaded media, modules, themes) |
| `sideload.tar.gz` | Sideload directory (only if non-empty) |
| `.env` | Environment variables (database password, admin credentials) |

## Backup

The backup script **stops all containers** during the process to guarantee data consistency, then **restarts them** automatically when done.

```bash
# Default: creates backups/<timestamp>/ in the project directory
bash scripts/backup.sh

# Or specify a custom path
bash scripts/backup.sh /path/to/backup-dir
```

**Downtime**: typically a few minutes depending on the size of your database and files.

## Restore (same server)

```bash
bash scripts/restore.sh backups/20260330-120000
```

> **Warning**: restoring on a server with existing data will **overwrite** the current database and files. You will be prompted for confirmation.

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

1. Copy `.env` from the backup if none exists
2. Restore the `omeka_files` volume (uploads, modules, themes)
3. Restore the `sideload` directory (if present in backup)
4. Start the database and wait for it to be healthy
5. Import the database dump
6. Start all services

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
- The `.env` file contains the database password. Keep your backups in a secure location.
- Both scripts are idempotent — safe to re-run if interrupted.
