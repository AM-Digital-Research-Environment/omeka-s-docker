#!/bin/bash
# Backup Omeka S Docker instance (database + files + sideload)
# Usage: bash scripts/backup.sh [backup-directory]
# Example: bash scripts/backup.sh
# Example: bash scripts/backup.sh /tmp/omeka-backup
#
# The script stops all containers before backing up to guarantee data
# consistency, then restarts them when done.
#
# Creates a timestamped directory with:
#   - omeka_db.sql       MySQL database dump
#   - omeka_files.tar.gz Omeka files volume (uploads, modules, themes)
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

echo "==> Omeka S Backup"
echo "    Project:   $PROJECT_DIR"
echo "    Backup to: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"

# --- 1. Stop web and php, keep db running for the dump ---
echo "==> Stopping web and php services..."
(cd "$PROJECT_DIR" && docker compose stop web php 2>/dev/null || true)

# Make sure db is running for the dump
if ! (cd "$PROJECT_DIR" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -q 'db'); then
    echo "==> Starting database for dump..."
    (cd "$PROJECT_DIR" && docker compose up -d db)
    echo "    Waiting for database to be healthy..."
    TRIES=0
    until (cd "$PROJECT_DIR" && docker compose exec -T db mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent 2>/dev/null); do
        TRIES=$((TRIES + 1))
        if [ "$TRIES" -ge 30 ]; then
            echo "ERROR: Database did not become ready."
            exit 1
        fi
        sleep 2
    done
fi

# --- 2. Database dump ---
echo "==> Dumping MySQL database..."
(cd "$PROJECT_DIR" && docker compose exec -T db mysqldump \
    -u"$MYSQL_USER" \
    -p"$MYSQL_PASSWORD" \
    --single-transaction --routines --triggers --no-tablespaces \
    "$MYSQL_DATABASE" \
) > "$BACKUP_DIR/omeka_db.sql"
echo "    Database: $(du -h "$BACKUP_DIR/omeka_db.sql" | cut -f1)"

# --- 3. Stop database before volume backup ---
echo "==> Stopping database..."
(cd "$PROJECT_DIR" && docker compose stop db)

# --- 4. Omeka files volume ---
echo "==> Backing up omeka_files volume..."
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

# --- 7. Restart all services ---
echo "==> Restarting all services..."
(cd "$PROJECT_DIR" && docker compose up -d)

echo ""
echo "==> Backup complete: $BACKUP_DIR"
ls -lhA "$BACKUP_DIR"
echo ""
echo "To migrate, copy this directory to the new server and run:"
echo "  bash scripts/restore.sh <backup-directory>"
