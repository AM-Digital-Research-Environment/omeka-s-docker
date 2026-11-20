#!/bin/bash
# Restore Omeka S Docker instance from a backup
# Usage: bash scripts/restore.sh [--force] <backup-directory>
# Example: bash scripts/restore.sh backups/20260617-082740
#
# Reads backups made by scripts/backup.sh. A site that does not come from this
# template (a classic Apache/PHP install, shared hosting, another image) is
# converted into this format first with scripts/import-external.sh; see
# docs/MIGRATING.md.
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
#   - secrets/<name>     Secret files (compose.secrets.yml; optional, each used
#                        if that file does not exist yet)
#   - caddy_data.tar.gz  Caddy certificates (compose.tls.yml; optional, restored
#                        only while compose.tls.yml is active)

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR=""
FORCE=false
RESTORE_SEARCH=false
HELPER_IMAGE="alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf"
# Prefix for each shell run in the db container: the password comes from the
# container's MYSQL_PASSWORD_FILE (compose.secrets.yml) or MYSQL_PASSWORD.
# shellcheck disable=SC2016 # expanded by the container's shell, not here
DB_PASSWORD_SH='pw="${MYSQL_PASSWORD:-}"; if [ -n "${MYSQL_PASSWORD_FILE:-}" ]; then pw="$(cat "$MYSQL_PASSWORD_FILE")"; fi; '

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=true
            ;;
        --restore-search)
            RESTORE_SEARCH=true
            ;;
        -h|--help)
            echo "Usage: bash scripts/restore.sh [--force] <backup-directory>"
            echo "  --force  overwrite existing volumes without an interactive prompt"
            echo "  --restore-search  also restore a legacy Typesense archive (best-effort)"
            echo "Restores a backup made by scripts/backup.sh. To move in a site that was not"
            echo "run from this template, convert it first: scripts/import-external.sh"
            echo "(see docs/MIGRATING.md)."
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
if [ -e "$BACKUP_DIR/BACKUP_INCOMPLETE" ]; then
    echo "ERROR: This backup did not finish; refusing to restore it." >&2
    exit 1
fi
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
        $2 !~ /^(BACKUP_FORMAT|omeka_db[.]sql|omeka_media[.]tar[.]gz|omeka_logs[.]tar[.]gz|omeka_modules[.]tar[.]gz|omeka_themes[.]tar[.]gz|omeka_files[.]tar[.]gz|caddy_data[.]tar[.]gz|typesense_data[.]tar[.]gz|sideload[.]tar[.]gz|local[.]config[.]php|images[.]json|[.]env|secrets[/][a-z0-9_]+)$/ ||
        seen[$2]++ { exit 1 }
        END { if (!seen["omeka_db.sql"]) exit 1 }
    ' "$BACKUP_DIR/SHA256SUMS"; then
        echo "ERROR: SHA256SUMS is malformed, incomplete, or contains unsafe paths." >&2
        exit 1
    fi
    secret_artifacts=()
    for file in "$BACKUP_DIR"/secrets/*; do
        [ ! -e "$file" ] || secret_artifacts+=("secrets/${file##*/}")
    done
    for artifact in BACKUP_FORMAT omeka_db.sql omeka_media.tar.gz omeka_logs.tar.gz omeka_modules.tar.gz omeka_themes.tar.gz omeka_files.tar.gz caddy_data.tar.gz typesense_data.tar.gz sideload.tar.gz local.config.php images.json .env "${secret_artifacts[@]}"; do
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

# --- Pre-flight: can this stack's MySQL import the dump as it is? ---
# A dump from somewhere else (MariaDB, another server's mysqldump options)
# can fail half-way through the import below, after the old database has
# already been dropped. Catch the known cases now, before anything changes;
# scripts/import-external.sh rewrites them. Dumps written by backup.sh have
# none of them (mysqldump without --databases writes no CREATE DATABASE/USE).
# Cost: one sequential read. The first grep only tests a fixed prefix and
# drops the data lines (INSERT ...), which are nearly all of a dump; the
# little that remains is searched for the patterns.
DUMP_FILE="$BACKUP_DIR/omeka_db.sql"
# Bounded, so a dump without line breaks is not read whole here.
dump_head="$(head -c 4096 "$DUMP_FILE" | head -n 5)"
dump_problems=()
if head -n 1 <<< "$dump_head" | grep -q '^/\*M\{0,1\}!999999\\- enable the sandbox mode'; then
    dump_problems+=("line 1 is MariaDB's sandbox-mode marker; the MySQL client stops on it (--fix-mariadb)")
fi
dump_statements="$(LC_ALL=C grep -v '^INSERT INTO ' "$DUMP_FILE" \
    | LC_ALL=C grep -E '^(USE |CREATE (DATABASE|SCHEMA) )|uca1400_' | head -n 50 || true)"
if grep -q 'uca1400_' <<< "$dump_statements"; then
    dump_problems+=("it uses MariaDB's utf8mb4_uca1400 collations, which MySQL 9 does not have (--fix-mariadb)")
fi
dump_usedb="$(LC_ALL=C grep -E -m 1 '^(USE |CREATE (DATABASE|SCHEMA) )' <<< "$dump_statements" || true)"
if [[ -n "$dump_usedb" ]]; then
    dump_problems+=("it switches databases (${dump_usedb:0:60}); the import must go into MYSQL_DATABASE (--fix-portability)")
fi
if ((${#dump_problems[@]})); then
    echo "ERROR: omeka_db.sql cannot be imported into this stack as it is:" >&2
    for problem in "${dump_problems[@]}"; do
        echo "       - $problem" >&2
    done
    echo "       It does not look like a dump made by scripts/backup.sh. Convert the site" >&2
    echo "       with scripts/import-external.sh and the options named above, then restore" >&2
    echo "       its output; see docs/MIGRATING.md. Nothing has been changed." >&2
    exit 1
fi
# mysqldump writes this trailer after its last statement (backup.sh insists on
# it); a dump with the header but without it was cut off.
if grep -qE '^-- (MySQL|MariaDB) dump' <<< "$dump_head" \
    && ! tail -c 200 "$DUMP_FILE" | grep -q '^-- Dump completed'; then
    echo "WARNING: omeka_db.sql has a mysqldump header but no '-- Dump completed' trailer;" >&2
    echo "         it is probably truncated. Check it before relying on this restore." >&2
fi

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

# Resolve compose project name for volume prefix
compose_args=()
[[ "$RESTORE_SEARCH" != true ]] || compose_args+=(--profile search)
COMPOSE_CONFIG="$(cd "$PROJECT_DIR" && docker compose "${compose_args[@]}" config --format json)"
volume_for() { python3 "$SCRIPT_DIR/compose-settings.py" volume "$@" <<< "$COMPOSE_CONFIG"; }
MEDIA_VOLUME="$(volume_for php /var/www/html/files)"
LOGS_VOLUME="$(volume_for php /var/www/html/logs)"
MYSQL_VOLUME="$(volume_for db /var/lib/mysql)"
MODULES_VOLUME="$(volume_for php /var/www/html/modules)"
THEMES_VOLUME="$(volume_for php /var/www/html/themes)"
# Empty unless compose.tls.yml (the bundled Caddy) is active here.
CADDY_VOLUME="$(volume_for caddy /data)"
TYPESENSE_VOLUME=""
if [[ "$RESTORE_SEARCH" == true && -f "$BACKUP_DIR/typesense_data.tar.gz" ]]; then
    TYPESENSE_VOLUME="$(volume_for typesense /data)"
    [[ -n "$TYPESENSE_VOLUME" ]] || { echo "No Typesense volume configured." >&2; exit 1; }
fi
[[ -n "$MEDIA_VOLUME" && -n "$LOGS_VOLUME" && -n "$MYSQL_VOLUME" ]] || {
    echo "Media, logs and database mounts must be configured named volumes." >&2; exit 1;
}

# --- 0b. Secret files (compose.secrets.yml) ---
# Compose refuses to start a service whose secret file is missing, so check
# now, before anything is stopped or overwritten. A missing file is taken from
# the backup (the files are placed after the confirmation below); an existing
# one is kept, like an existing .env: the database user's password lives in
# the mysql_data volume, which a restore does not replace.
SECRET_LINES="$(python3 "$SCRIPT_DIR/compose-settings.py" secrets <<< "$COMPOSE_CONFIG")"
SECRETS_TO_PLACE=()
if [[ -n "$SECRET_LINES" ]]; then
    while IFS=$'\t' read -r secret_name secret_path; do
        if [[ -f "$secret_path" ]]; then
            if [[ -f "$BACKUP_DIR/secrets/$secret_name" ]] \
                && ! cmp -s "$secret_path" "$BACKUP_DIR/secrets/$secret_name"; then
                echo "WARNING: $secret_path differs from the backup's copy; keeping the existing file." >&2
                if [[ "$secret_name" == omeka_secret_key ]]; then
                    echo "         Values Omeka encrypted with the backup's key stay unreadable until" >&2
                    echo "         that key is restored: $BACKUP_DIR/secrets/$secret_name" >&2
                fi
            fi
        elif [[ -f "$BACKUP_DIR/secrets/$secret_name" ]]; then
            SECRETS_TO_PLACE+=("$secret_name"$'\t'"$secret_path")
        else
            echo "ERROR: Secret file $secret_path is missing and the backup has no copy." >&2
            echo "       Create it first (see compose.secrets.yml); an empty file means unset." >&2
            exit 1
        fi
    done <<< "$SECRET_LINES"
elif [[ -d "$BACKUP_DIR/secrets" ]]; then
    echo "NOTE: This backup was taken with compose.secrets.yml; its secret files are in" >&2
    echo "      $BACKUP_DIR/secrets/. compose.secrets.yml is not active here, so they are" >&2
    echo "      not restored. OMEKA_SECRET_KEY in .env must match secrets/omeka_secret_key." >&2
fi

# --- 1. Confirm any destructive overwrite and stop running services ---
RUNNING="$(cd "$PROJECT_DIR" && docker compose ps --status running --format '{{.Service}}' 2>/dev/null | wc -l)"
DATA_EXISTS=false
RESTORE_CADDY_VOLUME=""
[[ ! -f "$BACKUP_DIR/caddy_data.tar.gz" ]] || RESTORE_CADDY_VOLUME="$CADDY_VOLUME"
for volume in "$MEDIA_VOLUME" "$LOGS_VOLUME" "$MYSQL_VOLUME" "$MODULES_VOLUME" "$THEMES_VOLUME" "$RESTORE_CADDY_VOLUME" "$TYPESENSE_VOLUME"; do
    if [[ -n "$volume" ]] && docker volume inspect "$volume" >/dev/null 2>&1; then
        DATA_EXISTS=true
    elif [[ -n "$volume" ]] && [[ "$(python3 "$SCRIPT_DIR/compose-settings.py" external "$volume" <<< "$COMPOSE_CONFIG")" == 1 ]]; then
        echo "ERROR: External volume $volume must be provisioned before restoring." >&2
        exit 1
    fi
done

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

for entry in "${SECRETS_TO_PLACE[@]}"; do
    secret_name="${entry%%$'\t'*}"
    secret_path="${entry#*$'\t'}"
    # 0700 directory, 0644 files: the containers read them as different uids
    # (see compose.secrets.yml), while other host users cannot reach them.
    # Only a directory created here gets its mode set; an existing one is the
    # operator's, and is left as it is.
    secret_dir="$(dirname "$secret_path")"
    if [[ ! -d "$secret_dir" ]]; then
        mkdir -p "$secret_dir"
        chmod 700 "$secret_dir"
    fi
    install -m 0644 "$BACKUP_DIR/secrets/$secret_name" "$secret_path"
    echo "==> Restored secret file $secret_path"
done

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
        if [[ "$name" == omeka_modules ]]; then EXT_VOLUME="$MODULES_VOLUME"; else EXT_VOLUME="$THEMES_VOLUME"; fi
        if [[ -z "$EXT_VOLUME" ]]; then
            echo "==> Skipping $name archive: extensions are image-managed."
            continue
        fi
        echo "==> Restoring ${name} volume..."
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

# --- 3c. Restore Caddy certificates (compose.tls.yml) ---
# Put back before Caddy starts, so it reuses the certificates and ACME
# account instead of requesting new ones (see backup.sh for why that
# matters). Without compose.tls.yml there is nowhere to put them; Caddy
# obtains new ones if the overlay is switched on later.
if [ -f "$BACKUP_DIR/caddy_data.tar.gz" ]; then
    if [[ -z "$CADDY_VOLUME" ]]; then
        echo "==> Skipping caddy_data archive: compose.tls.yml is not active here."
    else
        echo "==> Restoring Caddy certificates (caddy_data)..."
        docker volume create "$CADDY_VOLUME" > /dev/null 2>&1 || true
        docker run --rm \
            -v "$CADDY_VOLUME":/data \
            -v "$BACKUP_DIR":/backup:ro \
            "$HELPER_IMAGE" sh -eu -c '
                rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null || true
                tar xzf /backup/caddy_data.tar.gz -C /data
            '
        echo "    caddy_data volume restored."
    fi
fi

# --- 4. Restore Typesense data volume (optional search backend) ---
TYPESENSE_RESTORED=false
if [[ -f "$BACKUP_DIR/typesense_data.tar.gz" && "$RESTORE_SEARCH" == true ]]; then
    echo "==> Restoring Typesense data volume..."
    docker volume create "$TYPESENSE_VOLUME" > /dev/null 2>&1 || true
    docker run --rm \
        -v "$TYPESENSE_VOLUME":/data \
        -v "$BACKUP_DIR":/backup:ro \
        "$HELPER_IMAGE" sh -c "rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; cd /data && tar xzf /backup/typesense_data.tar.gz"
    TYPESENSE_RESTORED=true
    echo "    Typesense volume restored."
elif [[ -f "$BACKUP_DIR/typesense_data.tar.gz" ]]; then
    echo "==> Legacy search archive skipped; use --restore-search only if you need this best-effort copy."
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
    "$DB_PASSWORD_SH"'exec mysql -h 127.0.0.1 -u"$MYSQL_USER" -p"$pw" "$MYSQL_DATABASE" -e "SELECT 1"' >/dev/null 2>&1); do
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
# interpolating it into SQL; credentials stay inside the db container.
(cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c "$DB_PASSWORD_SH"'
    case "$MYSQL_DATABASE" in
        ""|*[!A-Za-z0-9_]*)
            echo "ERROR: MYSQL_DATABASE must contain only letters, digits, and underscores." >&2
            exit 1
            ;;
    esac
    exec mysql -u"$MYSQL_USER" -p"$pw" -e \
        "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
')
(cd "$PROJECT_DIR" && docker compose exec -T db sh -eu -c \
    "$DB_PASSWORD_SH"'exec mysql -u"$MYSQL_USER" -p"$pw" "$MYSQL_DATABASE"') \
    < "$BACKUP_DIR/omeka_db.sql"
echo "    Database imported."
if [[ "$TYPESENSE_RESTORED" != true ]]; then
    echo "==> Rebuild the search index from the restored Omeka database before enabling search for users."
fi

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
