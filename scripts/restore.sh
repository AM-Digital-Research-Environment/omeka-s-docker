#!/bin/bash
# Restore Omeka S Docker instance from a backup
# Usage: bash scripts/restore.sh <backup-directory>
# Example: bash scripts/restore.sh /tmp/omeka-backup/20260330-120000
#
# Expects the backup directory to contain:
#   - omeka_db.sql       MySQL database dump (required)
#   - omeka_files.tar.gz Omeka files volume (required)
#   - typesense_data.tar.gz Typesense search index (optional)
#   - sideload.tar.gz    Sideload directory (optional)
#   - .env               Environment file (optional, used if no .env exists)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="${1:-}"

if [ -z "$BACKUP_DIR" ]; then
    echo "Usage: bash scripts/restore.sh <backup-directory>"
    echo "Example: bash scripts/restore.sh backups/20260330-120000"
    exit 1
fi

# Resolve relative paths
if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$(pwd)/$BACKUP_DIR"
fi

# Validate backup contents
for f in omeka_db.sql omeka_files.tar.gz; do
    if [ ! -f "$BACKUP_DIR/$f" ]; then
        echo "ERROR: Missing required file: $BACKUP_DIR/$f"
        exit 1
    fi
done

echo "==> Omeka S Restore"
echo "    Project:      $PROJECT_DIR"
echo "    Restore from: $BACKUP_DIR"
echo ""

# --- 0. Handle .env ---
if [ ! -f "$PROJECT_DIR/.env" ]; then
    if [ -f "$BACKUP_DIR/.env" ]; then
        echo "==> No .env found, copying from backup..."
        cp "$BACKUP_DIR/.env" "$PROJECT_DIR/.env"
    else
        echo "ERROR: No .env in project or backup. Create one from .env.example first."
        exit 1
    fi
fi

MYSQL_PASSWORD="$(grep -E '^MYSQL_PASSWORD=' "$PROJECT_DIR/.env" | cut -d= -f2-)"
MYSQL_DATABASE="$(grep -E '^MYSQL_DATABASE=' "$PROJECT_DIR/.env" | cut -d= -f2- || echo omeka)"
MYSQL_USER="$(grep -E '^MYSQL_USER=' "$PROJECT_DIR/.env" | cut -d= -f2- || echo omeka)"
# Use defaults if not set in .env
MYSQL_DATABASE="${MYSQL_DATABASE:-omeka}"
MYSQL_USER="${MYSQL_USER:-omeka}"

# Resolve compose project name for volume prefix
COMPOSE_PROJECT="$(cd "$PROJECT_DIR" && docker compose config --format json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"

# --- 1. Warn if containers are already running ---
RUNNING="$(cd "$PROJECT_DIR" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null | wc -l)"
if [ "$RUNNING" -gt 0 ]; then
    echo "WARNING: $RUNNING service(s) already running."
    read -rp "Stop them and restore? This will OVERWRITE existing data. [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi
    echo "==> Stopping all services..."
    (cd "$PROJECT_DIR" && docker compose down)
fi

# --- 2. Restore omeka_files volume ---
echo "==> Restoring omeka_files volume..."
VOLUME_NAME="${COMPOSE_PROJECT}_omeka_files"
# Create volume if it doesn't exist
docker volume create "$VOLUME_NAME" > /dev/null 2>&1 || true
# Clear and restore
docker run --rm \
    -v "$VOLUME_NAME":/data \
    -v "$BACKUP_DIR":/backup:ro \
    alpine sh -c "rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; cd /data && tar xzf /backup/omeka_files.tar.gz"
echo "    Files volume restored."

# --- 3. Restore Typesense data volume (optional search backend) ---
TYPESENSE_RESTORED=false
if [ -f "$BACKUP_DIR/typesense_data.tar.gz" ]; then
    echo "==> Restoring Typesense data volume..."
    TYPESENSE_VOLUME="${COMPOSE_PROJECT}_typesense_data"
    docker volume create "$TYPESENSE_VOLUME" > /dev/null 2>&1 || true
    docker run --rm \
        -v "$TYPESENSE_VOLUME":/data \
        -v "$BACKUP_DIR":/backup:ro \
        alpine sh -c "rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; cd /data && tar xzf /backup/typesense_data.tar.gz"
    TYPESENSE_RESTORED=true
    echo "    Typesense volume restored."
fi

# --- 4. Restore sideload ---
if [ -f "$BACKUP_DIR/sideload.tar.gz" ]; then
    echo "==> Restoring sideload directory..."
    mkdir -p "$PROJECT_DIR/sideload"
    tar xzf "$BACKUP_DIR/sideload.tar.gz" -C "$PROJECT_DIR/sideload"
    echo "    Sideload restored."
fi

# --- 5. Start database and wait for it ---
echo "==> Starting database..."
(cd "$PROJECT_DIR" && docker compose up -d db)
echo "    Waiting for database to be healthy..."
TRIES=0
MAX_TRIES=30
until (cd "$PROJECT_DIR" && docker compose exec -T db mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent 2>/dev/null); do
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
        echo "ERROR: Database did not become ready after ${MAX_TRIES} attempts."
        exit 1
    fi
    sleep 2
done
echo "    Database is ready."

# --- 6. Import database dump ---
echo "==> Importing database dump..."
# Drop and recreate to ensure clean state
(cd "$PROJECT_DIR" && docker compose exec -T db mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
(cd "$PROJECT_DIR" && docker compose exec -T db mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE") < "$BACKUP_DIR/omeka_db.sql"
echo "    Database imported."

# --- 7. Start all services ---
echo "==> Starting all services..."
if [ "$TYPESENSE_RESTORED" = true ]; then
    # Restored a Typesense index — bring it back with the "search" profile.
    (cd "$PROJECT_DIR" && docker compose --profile search up -d)
else
    (cd "$PROJECT_DIR" && docker compose up -d)
fi

echo ""
echo "==> Restore complete!"
echo "    Waiting for services to become healthy..."
echo "    Run 'docker compose ps' to check status."
