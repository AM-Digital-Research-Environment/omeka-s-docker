#!/bin/bash
# Backup Omeka S Docker instance (database + files + sideload)
# Usage: bash scripts/backup.sh [backup-directory]
# Example: bash scripts/backup.sh
# Example: bash scripts/backup.sh /tmp/omeka-backup
#
# ZERO-DOWNTIME: this script keeps every container running. It does NOT stop
# web/php/db. Database consistency is guaranteed by mysqldump's
# --single-transaction: every table in this schema is InnoDB, so mysqldump opens
# one transaction with a consistent snapshot (START TRANSACTION WITH CONSISTENT
# SNAPSHOT) and dumps a single point-in-time view via MVCC while the live site
# keeps reading and writing. No global lock is taken, so writers are never
# blocked. See https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html
#
# THE ONE CAVEAT: --single-transaction is only isolated from DML, not DDL. A
# concurrent ALTER/CREATE/DROP/RENAME/TRUNCATE TABLE during the dump can corrupt
# it. Omeka issues DDL only when modules are installed/upgraded (or during a
# core upgrade), never during normal browsing/editing. So: do not run a module
# install/update or an Omeka upgrade while this backup runs. Routine traffic is
# always safe.
#
# Creates a timestamped directory with:
#   - omeka_db.sql       MySQL database dump
#   - omeka_files.tar.gz Omeka files volume (uploads, modules, themes)
#   - typesense_data.tar.gz Typesense search index (only if the search profile is in use)
#   - sideload.tar.gz    Sideload directory (if non-empty)
#   - .env               Environment file copy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${1:-$PROJECT_DIR/backups/$TIMESTAMP}"

# Read .env values
MYSQL_PASSWORD="$(grep -E '^MYSQL_PASSWORD=' "$PROJECT_DIR/.env" | cut -d= -f2-)"
MYSQL_DATABASE="$(grep -E '^MYSQL_DATABASE=' "$PROJECT_DIR/.env" | cut -d= -f2- 2>/dev/null || true)"
MYSQL_DATABASE="${MYSQL_DATABASE:-omeka}"
MYSQL_USER="$(grep -E '^MYSQL_USER=' "$PROJECT_DIR/.env" | cut -d= -f2- 2>/dev/null || true)"
MYSQL_USER="${MYSQL_USER:-omeka}"

# Resolve compose project name and volume prefix
COMPOSE_PROJECT="$(cd "$PROJECT_DIR" && docker compose config --format json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"

echo "==> Omeka S Backup (zero-downtime — containers stay up)"
echo "    Project:   $PROJECT_DIR"
echo "    Backup to: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"

# --- 1. Make sure the database is up for the dump ---
# We never stop it; just confirm it is running and reachable.
if ! (cd "$PROJECT_DIR" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -q 'db'); then
    echo "==> Starting database for dump..."
    (cd "$PROJECT_DIR" && docker compose up -d db)
fi
echo "==> Waiting for database to be reachable..."
TRIES=0
until (cd "$PROJECT_DIR" && docker compose exec -T db mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent 2>/dev/null); do
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge 30 ]; then
        echo "ERROR: Database did not become ready."
        exit 1
    fi
    sleep 2
done

# --- 2. Database dump (live, consistent, no lock) ---
echo "==> Dumping MySQL database (live, --single-transaction)..."
# --single-transaction : consistent InnoDB snapshot without locking writers.
# --set-gtid-purged=OFF : skip the consistent-GTID snapshot, which on MySQL 8.4+
#   requires the global RELOAD/FLUSH_TABLES privilege (a FLUSH TABLES WITH READ
#   LOCK). The unprivileged "omeka" user doesn't have it, and GTID purge info is
#   irrelevant for a single-server backup/restore, so turning it off is safe.
# --routines --triggers : include stored programs and triggers.
# --no-tablespaces : the "omeka" user lacks the PROCESS privilege CREATE
#   TABLESPACE statements would need on restore.
(cd "$PROJECT_DIR" && docker compose exec -T db mysqldump \
    -u"$MYSQL_USER" \
    -p"$MYSQL_PASSWORD" \
    --single-transaction --set-gtid-purged=OFF --routines --triggers --no-tablespaces \
    "$MYSQL_DATABASE" \
) > "$BACKUP_DIR/omeka_db.sql"
echo "    Database: $(du -h "$BACKUP_DIR/omeka_db.sql" | cut -f1)"

# --- 3. Omeka files volume (live) ---
# Omeka stores uploaded originals/thumbnails write-once under hashed names and
# never rewrites them in place, so a read-only tar of the live volume is
# consistent in practice. Mounted :ro so the helper can never disturb the data.
echo "==> Backing up omeka_files volume (live)..."
VOLUME_NAME="${COMPOSE_PROJECT}_omeka_files"
if docker volume inspect "$VOLUME_NAME" > /dev/null 2>&1; then
    docker run --rm \
        -v "$VOLUME_NAME":/data:ro \
        -v "$BACKUP_DIR":/backup \
        alpine tar czf /backup/omeka_files.tar.gz -C /data .
    echo "    Files:    $(du -h "$BACKUP_DIR/omeka_files.tar.gz" | cut -f1)"
else
    echo "    WARNING: Volume $VOLUME_NAME not found, skipping."
fi

# --- 4. Typesense data volume (optional search backend, live) ---
# The Typesense index is fully rebuildable from MySQL (re-index), so a live tar
# is acceptable here even if not perfectly atomic.
TYPESENSE_VOLUME="${COMPOSE_PROJECT}_typesense_data"
if docker volume inspect "$TYPESENSE_VOLUME" > /dev/null 2>&1; then
    echo "==> Backing up Typesense data volume (live)..."
    docker run --rm \
        -v "$TYPESENSE_VOLUME":/data:ro \
        -v "$BACKUP_DIR":/backup \
        alpine tar czf /backup/typesense_data.tar.gz -C /data .
    echo "    Typesense: $(du -h "$BACKUP_DIR/typesense_data.tar.gz" | cut -f1)"
else
    echo "==> Typesense not in use (no $TYPESENSE_VOLUME volume), skipping."
fi

# --- 5. Sideload directory ---
if [ -d "$PROJECT_DIR/sideload" ] && [ "$(ls -A "$PROJECT_DIR/sideload" 2>/dev/null)" ]; then
    echo "==> Backing up sideload directory..."
    tar czf "$BACKUP_DIR/sideload.tar.gz" -C "$PROJECT_DIR/sideload" .
    echo "    Sideload: $(du -h "$BACKUP_DIR/sideload.tar.gz" | cut -f1)"
else
    echo "==> Sideload directory is empty, skipping."
fi

# --- 6. Copy .env ---
if [ -f "$PROJECT_DIR/.env" ]; then
    cp "$PROJECT_DIR/.env" "$BACKUP_DIR/.env"
    echo "==> Copied .env"
fi

echo ""
echo "==> Backup complete: $BACKUP_DIR"
ls -lhA "$BACKUP_DIR"
echo ""
echo "To migrate, copy this directory to the new server and run:"
echo "  bash scripts/restore.sh <backup-directory>"
