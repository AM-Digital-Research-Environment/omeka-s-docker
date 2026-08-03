#!/bin/bash
# Backup Omeka S Docker instance (database + persistent data + sideload)
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
#   - BACKUP_FORMAT      Version/layout marker
#   - omeka_media.tar.gz Omeka uploaded media (immutable layout)
#   - omeka_logs.tar.gz  Omeka logs (immutable layout, if present)
#   - omeka_files.tar.gz Legacy whole document root (pre-migration only)
#   - typesense_data.tar.gz Typesense search index (only if the search profile is in use)
#   - sideload.tar.gz    Sideload directory (if non-empty)
#   - .env               Environment file copy
#   - local.config.php   Read-only Omeka deployment configuration

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${1:-$PROJECT_DIR/backups/$TIMESTAMP}"
HELPER_IMAGE="alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"

# Resolve compose project name and volume prefix
COMPOSE_PROJECT="$(cd "$PROJECT_DIR" && docker compose config --format json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"

echo "==> Omeka S Backup (zero-downtime — containers stay up)"
echo "    Project:   $PROJECT_DIR"
echo "    Backup to: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Determine the storage generation before doing any work. A partially created
# media volume without the marker must not hide a still-authoritative legacy
# whole-root volume after an interrupted migration attempt.
MEDIA_VOLUME="${COMPOSE_PROJECT}_omeka_media"
LOGS_VOLUME="${COMPOSE_PROJECT}_omeka_logs"
LEGACY_VOLUME="${COMPOSE_PROJECT}_omeka_files"
LAYOUT=""
if docker volume inspect "$MEDIA_VOLUME" >/dev/null 2>&1 \
    && docker run --rm -v "$MEDIA_VOLUME":/data:ro "$HELPER_IMAGE" \
        test -f /data/.immutable-layout-v1; then
    LAYOUT="immutable"
elif docker volume inspect "$LEGACY_VOLUME" >/dev/null 2>&1; then
    LAYOUT="legacy"
elif docker volume inspect "$MEDIA_VOLUME" >/dev/null 2>&1; then
    echo "ERROR: $MEDIA_VOLUME exists without the immutable-layout marker." >&2
    echo "       Complete or roll back the storage migration before backing up." >&2
    exit 1
else
    echo "ERROR: No Omeka media or legacy document-root volume was found." >&2
    exit 1
fi
printf 'omeka-docker-backup-v2\nlayout=%s\n' "$LAYOUT" > "$BACKUP_DIR/BACKUP_FORMAT"
echo "    Layout:    $LAYOUT"

# --- 1. Make sure the database is up for the dump ---
# We never stop it; just confirm it is running and reachable.
if ! (cd "$PROJECT_DIR" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx 'db'); then
    echo "==> Starting database for dump..."
    (cd "$PROJECT_DIR" && docker compose up -d db)
fi
echo "==> Waiting for database to be reachable..."
TRIES=0
until (cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c \
    'exec mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent' 2>/dev/null); do
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
(cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c '
    exec mysqldump \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASSWORD" \
        --single-transaction --set-gtid-purged=OFF --routines --triggers --no-tablespaces \
        "$MYSQL_DATABASE"
') > "$BACKUP_DIR/omeka_db.sql"
if [ ! -s "$BACKUP_DIR/omeka_db.sql" ]; then
    echo "ERROR: Database dump is empty." >&2
    exit 1
fi
echo "    Database: $(du -h "$BACKUP_DIR/omeka_db.sql" | cut -f1)"

# --- 3. Omeka persistent filesystem data (live) ---
if [ "$LAYOUT" = "immutable" ]; then
    echo "==> Backing up Omeka media volume (live)..."
    docker run --rm \
        -v "$MEDIA_VOLUME":/data:ro \
        -v "$BACKUP_DIR":/backup \
        "$HELPER_IMAGE" tar czf /backup/omeka_media.tar.gz -C /data .
    echo "    Media:    $(du -h "$BACKUP_DIR/omeka_media.tar.gz" | cut -f1)"

    if docker volume inspect "$LOGS_VOLUME" >/dev/null 2>&1; then
        echo "==> Backing up Omeka logs volume (live)..."
        docker run --rm \
            -v "$LOGS_VOLUME":/data:ro \
            -v "$BACKUP_DIR":/backup \
            "$HELPER_IMAGE" tar czf /backup/omeka_logs.tar.gz -C /data .
    fi
else
    echo "==> Backing up legacy whole document-root volume (live)..."
    echo "    WARNING: migrate this deployment with scripts/migrate-immutable-storage.sh"
    docker run --rm \
        -v "$LEGACY_VOLUME":/data:ro \
        -v "$BACKUP_DIR":/backup \
        "$HELPER_IMAGE" tar czf /backup/omeka_files.tar.gz -C /data .
    echo "    Legacy:   $(du -h "$BACKUP_DIR/omeka_files.tar.gz" | cut -f1)"
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
        "$HELPER_IMAGE" tar czf /backup/typesense_data.tar.gz -C /data .
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
    chmod 600 "$BACKUP_DIR/.env"
    echo "==> Copied .env"
fi

if [ "$LAYOUT" = "immutable" ]; then
    LOCAL_CONFIG_SOURCE="$(cd "$PROJECT_DIR" && docker compose config --format json \
        | python3 -c '
import json, sys
config = json.load(sys.stdin)
for mount in config["services"]["php"].get("volumes", []):
    if mount.get("target") == "/var/www/html/config/local.config.php":
        print(mount.get("source", ""))
        break
')"
    if [ -z "$LOCAL_CONFIG_SOURCE" ] || [ ! -f "$LOCAL_CONFIG_SOURCE" ]; then
        echo "ERROR: Cannot resolve the mounted Omeka local.config.php." >&2
        exit 1
    fi
    cp "$LOCAL_CONFIG_SOURCE" "$BACKUP_DIR/local.config.php"
    chmod 600 "$BACKUP_DIR/local.config.php"
    echo "==> Copied local.config.php"
fi

# --- 7. Record image provenance when containers exist ---
if (cd "$PROJECT_DIR" && docker compose images --format json) > "$BACKUP_DIR/images.json" 2>/dev/null \
    && [ -s "$BACKUP_DIR/images.json" ]; then
    echo "==> Recorded container image provenance"
else
    rm -f "$BACKUP_DIR/images.json"
fi

# --- 8. Integrity manifest ---
# This detects interrupted transfers and accidental corruption. It is not an
# authenticity signature: store the backup off-host and encrypt it separately.
CHECKSUM_FILES=(BACKUP_FORMAT omeka_db.sql)
for file in omeka_media.tar.gz omeka_logs.tar.gz omeka_files.tar.gz typesense_data.tar.gz sideload.tar.gz .env local.config.php images.json; do
    [ ! -f "$BACKUP_DIR/$file" ] || CHECKSUM_FILES+=("$file")
done
(cd "$BACKUP_DIR" && sha256sum "${CHECKSUM_FILES[@]}" > SHA256SUMS)
echo "==> Wrote SHA256SUMS"

echo ""
echo "==> Backup complete: $BACKUP_DIR"
ls -lhA "$BACKUP_DIR"
echo ""
echo "To migrate, copy this directory to the new server and run:"
echo "  bash scripts/restore.sh <backup-directory>"
