#!/bin/bash
# One-shot migration from the legacy /var/www/html volume to immutable code.
# Usage: bash scripts/migrate-immutable-storage.sh [--adopt-code]
#
# --adopt-code copies the exact legacy modules/themes into _docker/local-* before
# building. Use it when the version preflight reports that manifests do not yet
# reproduce the deployed extension set. The legacy volume is never deleted.

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER_IMAGE="alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
ADOPT_CODE=false

for arg in "$@"; do
    case "$arg" in
        --adopt-code) ADOPT_CODE=true ;;
        -h|--help)
            echo "Usage: bash scripts/migrate-immutable-storage.sh [--adopt-code]"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

cd "$PROJECT_DIR"
COMPOSE_PROJECT="$(docker compose config --format json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
LEGACY_VOLUME="${COMPOSE_PROJECT}_omeka_files"
MEDIA_VOLUME="${COMPOSE_PROJECT}_omeka_media"
LOGS_VOLUME="${COMPOSE_PROJECT}_omeka_logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$PROJECT_DIR/backups/pre-immutable-$TIMESTAMP"
TEMP_DIR="$(mktemp -d -t omeka-immutable-migration.XXXXXX)"

cleanup() {
    rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT

if ! docker volume inspect "$LEGACY_VOLUME" >/dev/null 2>&1; then
    if docker volume inspect "$MEDIA_VOLUME" >/dev/null 2>&1 \
        && docker run --rm -v "$MEDIA_VOLUME":/data:ro "$HELPER_IMAGE" \
            test -f /data/.immutable-layout-v1; then
        echo "Immutable media storage is already active; nothing to migrate."
        exit 0
    fi
    echo "ERROR: Legacy volume $LEGACY_VOLUME was not found." >&2
    exit 1
fi

if ! docker run --rm -v "$LEGACY_VOLUME":/legacy:ro "$HELPER_IMAGE" \
    test -d /legacy/files; then
    echo "ERROR: $LEGACY_VOLUME does not contain /files as expected." >&2
    exit 1
fi

echo "==> Creating mandatory pre-migration backup..."
bash scripts/backup.sh "$BACKUP_DIR"

# Preserve the deployment's PHP configuration outside the immutable image.
MIGRATED_CONFIG="$PROJECT_DIR/_docker/migrated-local.config.php"
if ! docker run --rm -v "$LEGACY_VOLUME":/legacy:ro "$HELPER_IMAGE" \
    cat /legacy/config/local.config.php > "$MIGRATED_CONFIG"; then
    rm -f "$MIGRATED_CONFIG"
    echo "ERROR: Could not extract legacy config/local.config.php." >&2
    exit 1
fi
chmod 644 "$MIGRATED_CONFIG"

local_code_is_empty() {
    local directory="$1"
    ! find "$directory" -mindepth 1 -maxdepth 1 ! -name .gitkeep -print -quit | grep -q .
}

if [ "$ADOPT_CODE" = true ]; then
    if ! local_code_is_empty _docker/local-modules \
        || ! local_code_is_empty _docker/local-themes; then
        echo "ERROR: _docker/local-modules or _docker/local-themes already contains code." >&2
        echo "       Reconcile it manually before using --adopt-code." >&2
        exit 1
    fi
    echo "==> Adopting exact legacy module/theme code into the build context..."
    docker run --rm -v "$LEGACY_VOLUME":/legacy:ro "$HELPER_IMAGE" \
        tar cf - -C /legacy/modules . | tar xf - -C _docker/local-modules
    docker run --rm -v "$LEGACY_VOLUME":/legacy:ro "$HELPER_IMAGE" \
        tar cf - -C /legacy/themes . | tar xf - -C _docker/local-themes
fi

echo "==> Building immutable PHP and nginx images..."
docker compose build php web

cat > "$TEMP_DIR/inventory.sh" <<'INVENTORY'
#!/bin/sh
set -eu
kind="$1"
case "$kind" in
    modules) ini=config/module.ini ;;
    themes) ini=config/theme.ini ;;
    *) exit 2 ;;
esac
for directory in "/var/www/html/$kind"/*; do
    [ -d "$directory" ] || continue
    [ -f "$directory/$ini" ] || continue
    version=$(awk -F= '
        /^[[:space:]]*version[[:space:]]*=/ {
            value = $2
            gsub(/^[[:space:]"\047]+|[[:space:]"\047]+$/, "", value)
            print value
            exit
        }
    ' "$directory/$ini")
    printf '%s\t%s\n' "$(basename "$directory")" "${version:-unknown}"
done | sort
INVENTORY

for kind in modules themes; do
    docker run --rm \
        -v "$LEGACY_VOLUME":/var/www/html:ro \
        -v "$TEMP_DIR":/migration-tools:ro \
        "$HELPER_IMAGE" sh /migration-tools/inventory.sh "$kind" \
        > "$TEMP_DIR/legacy-$kind"
    docker compose run --rm --no-deps \
        -v "$TEMP_DIR":/migration-tools:ro \
        --entrypoint sh php /migration-tools/inventory.sh "$kind" \
        > "$TEMP_DIR/image-$kind"
done

legacy_core="$(docker run --rm -v "$LEGACY_VOLUME":/var/www/html:ro "$HELPER_IMAGE" \
    sed -n 's/.*const VERSION[^0-9]*\([0-9.]*\).*/\1/p' /var/www/html/application/Module.php)"
image_core="$(docker compose run --rm --no-deps --entrypoint sed php \
    -n 's/.*const VERSION[^0-9]*\([0-9.]*\).*/\1/p' /var/www/html/application/Module.php)"

PREFLIGHT_FAILED=false
if [ -z "$legacy_core" ] || [ "$legacy_core" != "$image_core" ]; then
    echo "ERROR: Core version differs: legacy=${legacy_core:-unknown}, image=${image_core:-unknown}" >&2
    PREFLIGHT_FAILED=true
fi
for kind in modules themes; do
    if ! diff -u "$TEMP_DIR/legacy-$kind" "$TEMP_DIR/image-$kind"; then
        echo "ERROR: Legacy and image $kind differ." >&2
        PREFLIGHT_FAILED=true
    fi
done
if [ "$PREFLIGHT_FAILED" = true ]; then
    echo "" >&2
    echo "Migration stopped before touching running services." >&2
    echo "Pin the shown versions in _docker/extra-*.txt, or rerun with" >&2
    echo "--adopt-code to bake the exact deployed extension code." >&2
    exit 1
fi

echo ""
echo "Preflight passed: core, modules, and themes match exactly."
echo "Backup: $BACKUP_DIR"
read -rp "Stop services and migrate persistent data now? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Aborted before storage changes."
    exit 0
fi

if grep -q '^OMEKA_LOCAL_CONFIG=' .env; then
    sed -i 's|^OMEKA_LOCAL_CONFIG=.*|OMEKA_LOCAL_CONFIG=./_docker/migrated-local.config.php|' .env
else
    printf '\nOMEKA_LOCAL_CONFIG=./_docker/migrated-local.config.php\n' >> .env
fi

echo "==> Stopping services (legacy volume remains intact)..."
docker compose down

docker volume create \
    --label "com.docker.compose.project=$COMPOSE_PROJECT" \
    --label "com.docker.compose.volume=omeka_media" \
    "$MEDIA_VOLUME" >/dev/null
docker volume create \
    --label "com.docker.compose.project=$COMPOSE_PROJECT" \
    --label "com.docker.compose.volume=omeka_logs" \
    "$LOGS_VOLUME" >/dev/null

echo "==> Copying media and logs into dedicated volumes..."
docker run --rm \
    -v "$LEGACY_VOLUME":/legacy:ro \
    -v "$MEDIA_VOLUME":/media \
    -v "$LOGS_VOLUME":/logs \
    "$HELPER_IMAGE" sh -eu -c '
        rm -rf /media/* /media/..?* /media/.[!.]* 2>/dev/null || true
        rm -rf /logs/* /logs/..?* /logs/.[!.]* 2>/dev/null || true
        cp -a /legacy/files/. /media/
        if [ -d /legacy/logs ]; then cp -a /legacy/logs/. /logs/; fi
        touch /media/.immutable-layout-v1
    '

legacy_media_count="$(docker run --rm -v "$LEGACY_VOLUME":/data:ro "$HELPER_IMAGE" \
    sh -c 'find /data/files -type f | wc -l')"
new_media_count="$(docker run --rm -v "$MEDIA_VOLUME":/data:ro "$HELPER_IMAGE" \
    sh -c 'find /data -type f ! -name .immutable-layout-v1 | wc -l')"
if [ "$legacy_media_count" != "$new_media_count" ]; then
    echo "ERROR: Media verification failed ($legacy_media_count != $new_media_count)." >&2
    echo "Legacy volume is intact; do not start the new stack." >&2
    exit 1
fi

echo "==> Starting immutable stack..."
docker compose up -d

for service in db php web; do
    echo "    waiting for $service..."
    for _ in $(seq 1 60); do
        container_id="$(docker compose ps -q "$service")"
        status="$(docker inspect -f '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)"
        [ "$status" = healthy ] && break
        sleep 5
    done
    if [ "${status:-}" != healthy ]; then
        docker compose logs --tail 200 "$service" >&2 || true
        echo "ERROR: $service did not become healthy." >&2
        exit 1
    fi
done

docker compose exec -T php test -f /var/www/html/files/.immutable-layout-v1
docker compose exec -T php test ! -w /var/www/html/application/Module.php
docker compose exec -T php test ! -w /var/www/html/modules

echo ""
echo "Migration complete. Verified $new_media_count media files."
echo "The rollback volume remains untouched: $LEGACY_VOLUME"
echo "Keep it until the site, admin, media, modules, themes, and IIIF have been"
echo "verified and at least one new-format backup has been restored in staging."
