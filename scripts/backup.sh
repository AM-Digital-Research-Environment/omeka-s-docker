#!/bin/bash
# Backup Omeka S Docker instance (database + persistent data + sideload)
# Usage: bash scripts/backup.sh [--quiesce] [backup-directory]
# Example: bash scripts/backup.sh
# Example: bash scripts/backup.sh /tmp/omeka-backup
#
# By default containers stay running; --quiesce stops web/PHP temporarily.
# Database snapshot consistency relies on InnoDB tables and mysqldump's
# --single-transaction: with InnoDB, mysqldump opens
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
# safe for the SQL snapshot. File uploads/replacements/deletions can race the
# later media archive; pause editing and jobs for a strictly matched backup.
#
# Creates a timestamped directory with:
#   - omeka_db.sql       MySQL database dump
#   - BACKUP_FORMAT      Version/layout marker
#   - omeka_media.tar.gz Omeka uploaded media (immutable layout)
#   - omeka_logs.tar.gz  Omeka logs (immutable layout, if present)
#   - omeka_modules.tar.gz Admin-managed modules (default layout)
#   - omeka_themes.tar.gz  Admin-managed themes (default layout)
#   Search indexes are derived state and must be regenerated after recovery.
#   - sideload.tar.gz    Sideload directory (if non-empty)
#   - .env               Environment file copy
#   - local.config.php   Read-only Omeka deployment configuration

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=""
QUIESCE=false
for arg in "$@"; do
    case "$arg" in
        --quiesce) QUIESCE=true ;;
        -h|--help) echo "Usage: scripts/backup.sh [--quiesce] [backup-directory]"; exit 0 ;;
        -*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) [[ -z "$BACKUP_DIR" ]] || { echo "Only one backup directory is allowed." >&2; exit 2; }; BACKUP_DIR="$arg" ;;
    esac
done
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups/$TIMESTAMP}"
HELPER_IMAGE="alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"

# Resolve compose project name and volume prefix
COMPOSE_CONFIG="$(cd "$PROJECT_DIR" && docker compose config --format json)"
COMPOSE_PROJECT="$(python3 "$SCRIPT_DIR/compose-settings.py" project <<< "$COMPOSE_CONFIG")"
volume_for() { python3 "$SCRIPT_DIR/compose-settings.py" volume "$@" <<< "$COMPOSE_CONFIG"; }
MEDIA_VOLUME="$(volume_for php /var/www/html/files)"
LOGS_VOLUME="$(volume_for php /var/www/html/logs)"
MODULES_VOLUME="$(volume_for php /var/www/html/modules)"
THEMES_VOLUME="$(volume_for php /var/www/html/themes)"
[[ -n "$MEDIA_VOLUME" && -n "$LOGS_VOLUME" ]] || { echo "Media/logs mounts are required." >&2; exit 1; }

echo "==> Omeka S Backup (quiesce=$QUIESCE)"
echo "    Project:   $PROJECT_DIR"
echo "    Compose:   $COMPOSE_PROJECT"
echo "    Backup to: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
if [ -n "$(ls -A "$BACKUP_DIR")" ]; then
    echo "ERROR: Backup directory must be empty: $BACKUP_DIR" >&2
    exit 1
fi
chmod 700 "$BACKUP_DIR"
# An interrupted backup must never be mistaken for an old, unchecked archive.
touch "$BACKUP_DIR/BACKUP_INCOMPLETE"

# Refuse to back up a media volume that isn't the one this database belongs to.
# The marker is what distinguishes real media storage from a freshly created,
# empty volume — without this check a backup could silently capture nothing.
if ! docker volume inspect "$MEDIA_VOLUME" >/dev/null 2>&1; then
    echo "ERROR: Media volume $MEDIA_VOLUME was not found." >&2
    exit 1
fi
if ! docker run --rm -v "$MEDIA_VOLUME":/data:ro "$HELPER_IMAGE" \
    test -f /data/.immutable-layout-v1; then
    echo "ERROR: $MEDIA_VOLUME carries no layout marker — it is empty, or it is" >&2
    echo "       not the media volume this deployment uses. Refusing to write a" >&2
    echo "       backup that would appear complete while holding no media." >&2
    exit 1
fi
# restore.sh still reads layout=legacy archives written before August 2026.
printf 'omeka-docker-backup-v2\nlayout=immutable\n' > "$BACKUP_DIR/BACKUP_FORMAT"
echo "    Layout:    immutable"

# Opt-in maintenance window: only restart services this script actually stops.
# This also stops background jobs inside PHP. External writers must be paused
# by the operator. No Docker pause is used: in-flight writes finish on shutdown.
STOPPED_SERVICES=()
resume_services() {
    local status=$?
    trap - EXIT
    if ((${#STOPPED_SERVICES[@]})); then
        (cd "$PROJECT_DIR" && docker compose start "${STOPPED_SERVICES[@]}") || status=1
    fi
    exit "$status"
}
trap resume_services EXIT
if [[ "$QUIESCE" == true ]]; then
    running="$(cd "$PROJECT_DIR" && docker compose ps --status running --format '{{.Service}}')"
    for service in web php; do
        if grep -Fxq "$service" <<< "$running"; then
            STOPPED_SERVICES+=("$service")
        fi
    done
    if ((${#STOPPED_SERVICES[@]})); then
        (cd "$PROJECT_DIR" && docker compose stop "${STOPPED_SERVICES[@]}")
    fi
fi

# --- 1. Make sure the database is up for the dump ---
# We never stop it; just confirm it is running and reachable.
if ! (cd "$PROJECT_DIR" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx 'db'); then
    echo "==> Starting database for dump..."
    (cd "$PROJECT_DIR" && docker compose up -d db)
fi
echo "==> Waiting for database to be reachable..."
TRIES=0
until (cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c \
    'exec mysql -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "SELECT 1"' >/dev/null 2>&1); do
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
# --skip-masking-policies : MySQL 9.2 added masking policies to the default
#   dump, and reading them needs SELECT on the mysql schema, which the "omeka"
#   user does not have. Without this, every dump prints a scary "SELECT command
#   denied ... column_masking_policy" error. Omeka defines no masking policies,
#   so there is nothing to lose. The option does not exist before 9.2, so ask
#   this mysqldump whether it knows the flag rather than assuming a version.
MYSQLDUMP_EXTRA_OPTS=""
if (cd "$PROJECT_DIR" && docker compose exec -T db mysqldump --help 2>/dev/null) \
    | grep -- '--skip-masking-policies\|--masking-policies' >/dev/null; then
    MYSQLDUMP_EXTRA_OPTS="--skip-masking-policies"
fi
(cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c '
    exec mysqldump \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASSWORD" \
        --single-transaction --set-gtid-purged=OFF --routines --triggers --no-tablespaces \
        $1 \
        "$MYSQL_DATABASE"
' sh "$MYSQLDUMP_EXTRA_OPTS") > "$BACKUP_DIR/omeka_db.sql"
if [ ! -s "$BACKUP_DIR/omeka_db.sql" ]; then
    echo "ERROR: Database dump is empty." >&2
    exit 1
fi
# mysqldump can report a per-object error, skip that object and still exit 0, so
# a non-empty file is not proof of a whole dump. It writes this trailer only
# after the last statement, which a truncated or aborted dump never reaches.
if ! tail -c 200 "$BACKUP_DIR/omeka_db.sql" | grep -q '^-- Dump completed'; then
    echo "ERROR: Database dump is truncated (no completion marker)." >&2
    exit 1
fi
echo "    Database: $(du -h "$BACKUP_DIR/omeka_db.sql" | cut -f1)"

# --- 3. Omeka persistent filesystem data (live) ---
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

# --- 3b. Module/theme volumes (default layout, live) ---
# These volumes hold the admin-managed modules and themes. Deployments using
# compose.immutable.yml keep both in the image instead, so this is skipped.
# The caveat above applies doubly here: do not install/update modules or
# themes while the backup runs.
for name in omeka_modules omeka_themes; do
    if [[ "$name" == omeka_modules ]]; then VOLUME="$MODULES_VOLUME"; else VOLUME="$THEMES_VOLUME"; fi
    if [[ -n "$VOLUME" ]] && docker volume inspect "$VOLUME" > /dev/null 2>&1; then
        echo "==> Backing up ${name} volume (live)..."
        docker run --rm \
            -v "$VOLUME":/data:ro \
            -v "$BACKUP_DIR":/backup \
            "$HELPER_IMAGE" tar czf "/backup/${name}.tar.gz" -C /data .
        echo "    ${name}: $(du -h "$BACKUP_DIR/${name}.tar.gz" | cut -f1)"
    fi
done

# --- 4. Search is derived state ---
# A live tar of Typesense's database is not a supported snapshot. Re-index from
# Omeka after disaster recovery instead of presenting it as a reliable backup.
echo "==> Search index omitted; regenerate it from Omeka after recovery."

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
for file in omeka_media.tar.gz omeka_logs.tar.gz omeka_modules.tar.gz omeka_themes.tar.gz typesense_data.tar.gz sideload.tar.gz .env local.config.php images.json; do
    [ ! -f "$BACKUP_DIR/$file" ] || CHECKSUM_FILES+=("$file")
done
(cd "$BACKUP_DIR" && sha256sum "${CHECKSUM_FILES[@]}" > SHA256SUMS)
rm "$BACKUP_DIR/BACKUP_INCOMPLETE"
echo "==> Wrote SHA256SUMS"

echo ""
echo "==> Backup complete: $BACKUP_DIR"
ls -lhA "$BACKUP_DIR"
echo ""
echo "To migrate, copy this directory to the new server and run:"
echo "  bash scripts/restore.sh <backup-directory>"
