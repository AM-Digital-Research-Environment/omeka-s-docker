#!/bin/bash
# Restore Omeka S Docker instance from a backup
# Usage: bash scripts/restore.sh [--force] <backup-directory>
# Example: bash scripts/restore.sh backups/20260617-082740
#
# Expects the backup directory to contain:
#   - omeka_db.sql       MySQL database dump (required)
#   - omeka_media.tar.gz Omeka media volume (current format), or
#   - omeka_files.tar.gz Legacy whole document root (pre-migration format)
#   - omeka_modules.tar.gz Admin-managed modules (default layout, optional)
#   - omeka_themes.tar.gz  Admin-managed themes (default layout, optional)
#   - typesense_data.tar.gz Typesense search index (optional)
#   - sideload.tar.gz    Sideload directory (optional)
#   - .env               Environment file (optional, used if no .env exists)

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR=""
FORCE=false
HELPER_IMAGE="alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=true
            ;;
        -h|--help)
            echo "Usage: bash scripts/restore.sh [--force] <backup-directory>"
            echo "  --force  overwrite existing volumes without an interactive prompt"
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown option: $arg" >&2
            exit 1
            ;;
        *)
            if [ -n "$BACKUP_DIR" ]; then
                echo "ERROR: Only one backup directory may be specified." >&2
                exit 1
            fi
            BACKUP_DIR="$arg"
            ;;
    esac
done

if [ -z "$BACKUP_DIR" ]; then
    echo "Usage: bash scripts/restore.sh [--force] <backup-directory>"
    echo "Example: bash scripts/restore.sh backups/20260330-120000"
    exit 1
fi

# Resolve relative paths
if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$(pwd)/$BACKUP_DIR"
fi

# Detect the backup generation and validate its required data artifact.
LAYOUT="legacy"
if [ -f "$BACKUP_DIR/BACKUP_FORMAT" ]; then
    if [ "$(sed -n '1p' "$BACKUP_DIR/BACKUP_FORMAT")" != "omeka-docker-backup-v2" ]; then
        echo "ERROR: Unsupported backup format." >&2
        exit 1
    fi
    LAYOUT="$(sed -n 's/^layout=//p' "$BACKUP_DIR/BACKUP_FORMAT")"
    if [ "$LAYOUT" != "immutable" ] && [ "$LAYOUT" != "legacy" ]; then
        echo "ERROR: Invalid layout in BACKUP_FORMAT." >&2
        exit 1
    fi
fi

REQUIRED_FILES=(omeka_db.sql)
if [ "$LAYOUT" = "immutable" ]; then
    REQUIRED_FILES+=(omeka_media.tar.gz local.config.php)
else
    REQUIRED_FILES+=(omeka_files.tar.gz)
fi
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$BACKUP_DIR/$f" ]; then
        echo "ERROR: Missing required file: $BACKUP_DIR/$f"
        exit 1
    fi
done

# Verify before touching the target. Older backups remain restorable, but new
# backups always include this manifest.
if [ -f "$BACKUP_DIR/SHA256SUMS" ]; then
    echo "==> Verifying backup checksums..."
    # Accept only the fixed artifact names this project creates. Besides making
    # accidental truncation obvious, this prevents a crafted manifest from
    # making sha256sum read paths outside the backup directory.
    if ! awk '
        NF != 2 || length($1) != 64 || $1 !~ /^[0-9A-Fa-f]+$/ ||
        $2 !~ /^(BACKUP_FORMAT|omeka_db[.]sql|omeka_media[.]tar[.]gz|omeka_logs[.]tar[.]gz|omeka_modules[.]tar[.]gz|omeka_themes[.]tar[.]gz|omeka_files[.]tar[.]gz|typesense_data[.]tar[.]gz|sideload[.]tar[.]gz|local[.]config[.]php|images[.]json|[.]env)$/ ||
        seen[$2]++ { exit 1 }
        END { if (!seen["omeka_db.sql"]) exit 1 }
    ' "$BACKUP_DIR/SHA256SUMS"; then
        echo "ERROR: SHA256SUMS is malformed, incomplete, or contains unsafe paths." >&2
        exit 1
    fi
    for artifact in BACKUP_FORMAT omeka_db.sql omeka_media.tar.gz omeka_logs.tar.gz omeka_modules.tar.gz omeka_themes.tar.gz omeka_files.tar.gz typesense_data.tar.gz sideload.tar.gz local.config.php images.json .env; do
        if [ -f "$BACKUP_DIR/$artifact" ] \
            && ! awk -v name="$artifact" '$2 == name { found = 1 } END { exit !found }' "$BACKUP_DIR/SHA256SUMS"; then
            echo "ERROR: $artifact exists but is not covered by SHA256SUMS." >&2
            exit 1
        fi
    done
    (cd "$BACKUP_DIR" && sha256sum --check SHA256SUMS)
else
    echo "WARNING: No SHA256SUMS found; integrity cannot be verified." >&2
fi
echo "    Backup layout: $LAYOUT"

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

# Restore the exact read-only deployment config separately from the image. The
# database secret remains ephemeral under /run and is never written here.
RESTORED_CONFIG="$PROJECT_DIR/_docker/restored-local.config.php"
if [ -f "$BACKUP_DIR/local.config.php" ]; then
    cp "$BACKUP_DIR/local.config.php" "$RESTORED_CONFIG"
elif [ "$LAYOUT" = "legacy" ]; then
    if ! docker run --rm -v "$BACKUP_DIR":/backup:ro "$HELPER_IMAGE" sh -eu -c '
        path=$(tar tzf /backup/omeka_files.tar.gz | sed -n "s#^\(./\)\?config/local[.]config[.]php$#&#p" | head -n 1)
        test -n "$path"
        tar xOzf /backup/omeka_files.tar.gz "$path"
    ' > "$RESTORED_CONFIG"; then
        rm -f "$RESTORED_CONFIG"
        echo "ERROR: Legacy backup has no readable config/local.config.php." >&2
        exit 1
    fi
fi
if [ -f "$RESTORED_CONFIG" ]; then
    chmod 644 "$RESTORED_CONFIG"
    if grep -q '^OMEKA_LOCAL_CONFIG=' "$PROJECT_DIR/.env"; then
        sed -i 's|^OMEKA_LOCAL_CONFIG=.*|OMEKA_LOCAL_CONFIG=./_docker/restored-local.config.php|' "$PROJECT_DIR/.env"
    else
        printf '\nOMEKA_LOCAL_CONFIG=./_docker/restored-local.config.php\n' >> "$PROJECT_DIR/.env"
    fi
    echo "==> Restored local.config.php as a read-only deployment config"
fi

# Resolve compose project name for volume prefix
COMPOSE_PROJECT="$(cd "$PROJECT_DIR" && docker compose config --format json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"

# --- 1. Confirm any destructive overwrite and stop running services ---
RUNNING="$(cd "$PROJECT_DIR" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null | wc -l)"
MEDIA_VOLUME="${COMPOSE_PROJECT}_omeka_media"
LOGS_VOLUME="${COMPOSE_PROJECT}_omeka_logs"
LEGACY_VOLUME="${COMPOSE_PROJECT}_omeka_files"
MYSQL_VOLUME="${COMPOSE_PROJECT}_mysql_data"
DATA_EXISTS=false
if docker volume inspect "$MEDIA_VOLUME" >/dev/null 2>&1 \
    || docker volume inspect "$LEGACY_VOLUME" >/dev/null 2>&1 \
    || docker volume inspect "$MYSQL_VOLUME" >/dev/null 2>&1; then
    DATA_EXISTS=true
fi

if [ "$DATA_EXISTS" = true ] && [ "$FORCE" != true ]; then
    echo "WARNING: Existing Omeka/MySQL volumes will be overwritten."
    read -rp "Proceed with restore? This will OVERWRITE existing data. [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi
fi
if [ "$RUNNING" -gt 0 ]; then
    echo "==> Stopping $RUNNING running service(s)..."
    (cd "$PROJECT_DIR" && docker compose down)
fi

# --- 2. Restore media into the immutable storage layout ---
echo "==> Restoring Omeka media volume..."
docker volume create "$MEDIA_VOLUME" > /dev/null 2>&1 || true
if [ "$LAYOUT" = "immutable" ]; then
    docker run --rm \
        -v "$MEDIA_VOLUME":/data \
        -v "$BACKUP_DIR":/backup:ro \
        "$HELPER_IMAGE" sh -eu -c '
            rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null || true
            tar xzf /backup/omeka_media.tar.gz -C /data
            test -f /data/.immutable-layout-v1
        '
else
    # Legacy archives contain the entire document root. Extract only files/
    # into the new media volume and leave all old executable code behind.
    docker run --rm \
        -v "$MEDIA_VOLUME":/data \
        -v "$BACKUP_DIR":/backup:ro \
        "$HELPER_IMAGE" sh -eu -c '
            rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null || true
            mkdir /data/.legacy-root
            tar xzf /backup/omeka_files.tar.gz -C /data/.legacy-root
            test -d /data/.legacy-root/files
            cp -a /data/.legacy-root/files/. /data/
            rm -rf /data/.legacy-root
            touch /data/.immutable-layout-v1
        '
fi
echo "    Media volume restored."

# --- 3. Restore logs (optional operational history) ---
docker volume create "$LOGS_VOLUME" > /dev/null 2>&1 || true
if [ -f "$BACKUP_DIR/omeka_logs.tar.gz" ]; then
    echo "==> Restoring Omeka logs volume..."
    docker run --rm \
        -v "$LOGS_VOLUME":/data \
        -v "$BACKUP_DIR":/backup:ro \
        "$HELPER_IMAGE" sh -eu -c '
            rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null || true
            tar xzf /backup/omeka_logs.tar.gz -C /data
        '
elif [ "$LAYOUT" = "legacy" ]; then
    docker run --rm \
        -v "$LOGS_VOLUME":/data \
        -v "$BACKUP_DIR":/backup:ro \
        "$HELPER_IMAGE" sh -eu -c '
            rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null || true
            mkdir /data/.legacy-root
            tar xzf /backup/omeka_files.tar.gz -C /data/.legacy-root
            if [ -d /data/.legacy-root/logs ]; then cp -a /data/.legacy-root/logs/. /data/; fi
            rm -rf /data/.legacy-root
        '
fi

# --- 3b. Restore module/theme volumes (default layout) ---
# Absent from backups of deployments that use compose.immutable.yml. Restoring
# them before services start means the php container never re-seeds the volumes
# from the image, so the admin-managed extension state comes back exactly as
# backed up.
for name in omeka_modules omeka_themes; do
    if [ -f "$BACKUP_DIR/${name}.tar.gz" ]; then
        echo "==> Restoring ${name} volume..."
        EXT_VOLUME="${COMPOSE_PROJECT}_${name}"
        docker volume create "$EXT_VOLUME" > /dev/null 2>&1 || true
        docker run --rm \
            -e "ARCHIVE=${name}.tar.gz" \
            -v "$EXT_VOLUME":/data \
            -v "$BACKUP_DIR":/backup:ro \
            "$HELPER_IMAGE" sh -eu -c '
                rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null || true
                tar xzf "/backup/$ARCHIVE" -C /data
            '
        echo "    ${name} volume restored."
    fi
done

# --- 4. Restore Typesense data volume (optional search backend) ---
TYPESENSE_RESTORED=false
if [ -f "$BACKUP_DIR/typesense_data.tar.gz" ]; then
    echo "==> Restoring Typesense data volume..."
    TYPESENSE_VOLUME="${COMPOSE_PROJECT}_typesense_data"
    docker volume create "$TYPESENSE_VOLUME" > /dev/null 2>&1 || true
    docker run --rm \
        -v "$TYPESENSE_VOLUME":/data \
        -v "$BACKUP_DIR":/backup:ro \
        "$HELPER_IMAGE" sh -c "rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; cd /data && tar xzf /backup/typesense_data.tar.gz"
    TYPESENSE_RESTORED=true
    echo "    Typesense volume restored."
fi

# --- 5. Restore sideload ---
if [ -f "$BACKUP_DIR/sideload.tar.gz" ]; then
    echo "==> Restoring sideload directory..."
    mkdir -p "$PROJECT_DIR/sideload"
    tar xzf "$BACKUP_DIR/sideload.tar.gz" -C "$PROJECT_DIR/sideload"
    echo "    Sideload restored."
fi

# --- 6. Start database and wait for it ---
echo "==> Starting database..."
(cd "$PROJECT_DIR" && docker compose up -d db)
echo "    Waiting for database to be healthy..."
TRIES=0
MAX_TRIES=30
until (cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c \
    'exec mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent' 2>/dev/null); do
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
        echo "ERROR: Database did not become ready after ${MAX_TRIES} attempts."
        exit 1
    fi
    sleep 2
done
echo "    Database is ready."

# --- 7. Import database dump ---
echo "==> Importing database dump..."
# Drop and recreate to ensure clean state. Restrict the identifier before
# interpolating it into SQL; credentials stay in the container environment.
(cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c '
    case "$MYSQL_DATABASE" in
        ""|*[!A-Za-z0-9_]*)
            echo "ERROR: MYSQL_DATABASE must contain only letters, digits, and underscores." >&2
            exit 1
            ;;
    esac
    exec mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e \
        "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
')
(cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c \
    'exec mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"') \
    < "$BACKUP_DIR/omeka_db.sql"
echo "    Database imported."

# --- 8. Start all services ---
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
