#!/usr/bin/env bash
# CI smoke test: boots the stack, waits for health, probes HTTP behaviour,
# and tears down (including volumes). Two variants:
#
#   smoke.sh base   — generic template only, no admin env vars (the same path
#                     the one-click bootstrap produces).
#   smoke.sh amira  — base + AMIRA overlay activated via COMPOSE_FILE in .env,
#                     admin env vars set, search profile on. The amira-mcp
#                     service itself is NOT built (external repo with a
#                     build-time data fetch); /mcp answering 502 instead of
#                     404 proves the overlay's nginx location is wired in.
#
# Honours SMOKE_HTTP_PORT (default 80) for hosts where 80 is taken.

set -Eeuo pipefail

variant="${1:?usage: smoke.sh base|amira}"
port="${SMOKE_HTTP_PORT:-80}"
url="http://127.0.0.1:${port}"
created_env=false
stack_started=false
backup_dir=""
probe_module_dir="_docker/local-modules/ImmutableProbe"

log() { printf '\n==> %s\n' "$*"; }

on_error() {
    [[ "$stack_started" == true ]] || return 0
    log "FAILURE — service state and logs:"
    docker compose ps || true
    docker compose logs --tail 200 || true
}
trap on_error ERR

cleanup() {
    local status=$?
    trap - ERR EXIT
    if [[ "$stack_started" == true ]]; then
        docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
        rm -rf -- "$backup_dir"
    fi
    rm -rf -- "$probe_module_dir"
    rm -f -- _docker/restored-local.config.php
    if [[ "$created_env" == true ]]; then
        rm -f .env
    fi
    exit "$status"
}
trap cleanup EXIT

# Never clobber a developer's real .env.
if [[ -f .env && "${CI:-}" != "true" ]]; then
    echo "Refusing to overwrite an existing .env outside CI." >&2
    exit 1
fi

case "$variant" in
    base)
        cat > .env <<EOF
COMPOSE_PROJECT_NAME=omeka-smoke-base-${GITHUB_RUN_ID:-$$}
MYSQL_DATABASE=omeka_ci
MYSQL_USER=omeka_ci
MYSQL_PASSWORD="ci-mysql-password-with-special-#=chars"
NGINX_PORT=${port}
EOF
        ;;
    amira)
        cat > .env <<EOF
COMPOSE_PROJECT_NAME=omeka-smoke-amira-${GITHUB_RUN_ID:-$$}
MYSQL_DATABASE=omeka_ci
MYSQL_USER=omeka_ci
MYSQL_PASSWORD="ci-mysql-password-with-special-#=chars"
NGINX_PORT=${port}
COMPOSE_FILE=docker-compose.yml:compose.amira.yml
COMPOSE_PROFILES=search
SERVER_NAME=ci.example.org
TYPESENSE_API_KEY=ci-typesense-key
FRAME_ANCESTORS="'self' https://embed.example.org"
OMEKA_ADMIN_EMAIL=admin@example.com
OMEKA_ADMIN_USERNAME=ci-admin
OMEKA_ADMIN_PASSWORD=ci-admin-password
OMEKA_TITLE=CI Smoke Test
EOF
        ;;
    *)
        echo "Unknown variant: $variant" >&2
        exit 1
        ;;
esac
created_env=true

log "Booting stack ($variant)..."
stack_started=true
if [[ "$variant" == "amira" ]]; then
    docker compose up -d --build web php db typesense
else
    docker compose up -d --build
fi

wait_healthy() {
    local deadline=$((SECONDS + 600)) svc cid status
    for svc in "$@"; do
        while :; do
            cid=$(docker compose ps -q "$svc")
            status=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo unknown)
            if [[ "$status" == "healthy" ]]; then
                echo "    $svc: healthy"
                break
            fi
            if (( SECONDS > deadline )); then
                echo "Timed out waiting for $svc (last status: $status)" >&2
                return 1
            fi
            sleep 5
        done
    done
}

log "Waiting for services to become healthy..."
if [[ "$variant" == "amira" ]]; then
    wait_healthy db php web typesense
else
    wait_healthy db php web
fi

log "Checking runtime hardening..."
for svc in web php db; do
    cid=$(docker compose ps -q "$svc")
    docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$cid" | grep -F 'no-new-privileges:true'
    docker inspect -f '{{json .HostConfig.CapDrop}}' "$cid" | grep -F 'ALL'
done
[[ "$(docker inspect -f '{{.Config.User}}' "$(docker compose ps -q php)")" == "www-data" ]]
[[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$(docker compose ps -q web)")" == "true" ]]
[[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$(docker compose ps -q php)")" == "true" ]]
for svc in php db; do
    [[ -z "$(docker port "$(docker compose ps -q "$svc")")" ]]
done
if [[ "$variant" == "amira" ]]; then
    cid=$(docker compose ps -q typesense)
    docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$cid" | grep -F 'no-new-privileges:true'
    docker inspect -f '{{json .HostConfig.CapDrop}}' "$cid" | grep -F 'ALL'
    [[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$cid")" == "true" ]]
    [[ -z "$(docker port "$cid")" ]]
fi
docker compose exec -T php sh -eu -c '
    test -f /var/www/html/files/.immutable-layout-v1
    ! touch /var/www/html/application/.ci-must-not-write
    printf %s writable > /var/www/html/files/.ci-media-write
    rm /var/www/html/files/.ci-media-write
'
docker compose exec -T web sh -eu -c '
    test -f /var/www/html/files/.immutable-layout-v1
    ! touch /var/www/html/files/.ci-must-not-write
'
echo "    capabilities, users, immutable code, media permissions, and port exposure: OK"

log "Checking PHP/Omeka runtime..."
docker compose exec -T php php -r '
    $required = ["apcu", "gd", "imagick", "intl", "mysqli", "pdo_mysql", "zip"];
    $missing = array_values(array_filter($required, fn ($ext) => !extension_loaded($ext)));
    if ($missing) { fwrite(STDERR, "Missing PHP extensions: " . implode(", ", $missing) . "\n"); exit(1); }
    if (getenv("MYSQL_DATABASE") !== "omeka_ci" || getenv("MYSQL_USER") !== "omeka_ci") {
        fwrite(STDERR, "Custom database settings did not reach PHP.\n"); exit(1);
    }
'
docker compose exec -T php composer --version --no-ansi
# -L is required: config/database.ini is a symlink into /run/omeka (tmpfs), and
# stat without it reports the link's own mode (always 777), not the target's.
[[ "$(docker compose exec -T php stat -L -c '%a' /var/www/html/config/database.ini | tr -d '\r')" == "600" ]]
docker compose exec -T php php -r '
    $source = file_get_contents("/var/www/html/application/Module.php");
    if (!preg_match("/const VERSION\\s*=\\s*[^0-9]*([0-9.]+)/", $source, $match)) { exit(1); }
    if ($match[1] !== getenv("OMEKA_VERSION")) {
        fwrite(STDERR, "Omeka version mismatch: {$match[1]} != " . getenv("OMEKA_VERSION") . "\n"); exit(1);
    }
    echo "    Omeka S {$match[1]} with required PHP extensions and protected DB config: OK\n";
'

probe() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

log "Probing front page..."
code=$(probe "$url/")
echo "    GET / -> $code"
[[ "$code" =~ ^(200|30[123])$ ]]

log "Checking private paths are not web-accessible (regression guard)..."
# nginx must refuse Omeka's config/source/logs/deps and any stray .php.
# database.ini leaking here once exposed live DB credentials — never again.
private_paths=(
    /config/database.ini
    /composer.json
    /composer.lock
    /application/src/Module.php
    /vendor/autoload.php
    /uploads.ini
    /index.php/../config/database.ini
    # Modules and themes ship their whole source tree into the document root.
    # Only asset/ is public: their dependency manifests otherwise enumerate
    # exact package versions for an attacker to match against known CVEs.
    /modules/Common/composer.json
    /modules/Common/composer.lock
    /modules/Common/vendor/composer/installed.json
    /modules/Common/README.md
    /modules/Common/config/module.ini
    /themes/Freedom/composer.json
    /themes/Freedom/package.json
    /themes/Freedom/config/theme.ini
)
for p in "${private_paths[@]}"; do
    code=$(probe "$url$p")
    echo "    GET $p -> $code"
    [[ "$code" == "404" ]] || { echo "SECURITY: $p is reachable ($code)!" >&2; exit 1; }
done
# Public asset subtrees under application/ must still load.
code=$(probe "$url/application/asset/css/style.css")
echo "    GET /application/asset/css/style.css -> $code"
[[ "$code" == "200" ]]
# ...and so must module/theme assets plus the theme thumbnail Omeka's admin
# theme picker loads from /themes/<id>/theme.jpg (the one allow-listed file
# outside asset/).
for p in /themes/Freedom/theme.jpg /themes/Freedom/asset/css/style.css; do
    code=$(probe "$url$p")
    echo "    GET $p -> $code"
    [[ "$code" == "200" ]] || { echo "REGRESSION: $p must stay public ($code)!" >&2; exit 1; }
done

log "Probing admin (single shot — the login location is rate-limited)..."
code=$(curl -s -o /dev/null -w '%{http_code}' -L "$url/admin")
echo "    GET /admin (followed) -> $code"
[[ "$code" == "200" ]]

log "Checking CSP frame-ancestors header..."
headers=$(curl -sI "$url/")
if [[ "$variant" == "amira" ]]; then
    echo "$headers" | grep -Fi "frame-ancestors 'self' https://embed.example.org"
else
    echo "$headers" | grep -Fi "frame-ancestors 'self'"
fi

log "Probing /mcp routing..."
code=$(probe "$url/mcp")
echo "    GET /mcp -> $code"
if [[ "$variant" == "amira" ]]; then
    # Location present, upstream intentionally absent.
    [[ "$code" == "502" ]]
else
    # No MCP location in the base stack — Omeka must handle the URL.
    [[ "$code" != "502" ]]
fi

log "Checking baked modules..."
if [[ "$variant" == "amira" ]]; then
    docker compose exec -T php test -d /var/www/html/modules/DRESearch
    docker compose exec -T web test -d /var/www/html/modules/DRESearch
    # Vendored via LOCAL_THEMES_DIR; the directory name must survive the build
    # because the site rows select the theme by it.
    docker compose exec -T php test -d /var/www/html/themes/DRE-theme
    docker compose exec -T web test -d /var/www/html/themes/DRE-theme
    docker compose exec -T php test ! -d /var/www/html/themes/Africa_Multiple_____DRE
    echo "    DRESearch and DRE-theme present (overlay bakes DRE code)"
else
    docker compose exec -T php test ! -d /var/www/html/modules/DRESearch
    docker compose exec -T php test ! -d /var/www/html/modules/ImmutableProbe
    # The generic base image must carry no deployment-specific code: no AMIRA
    # modules and no AMIRA theme, however they were declared.
    docker compose exec -T php test ! -d /var/www/html/themes/DRE-theme
    docker compose exec -T web test ! -d /var/www/html/themes/DRE-theme
    for amira_module in DRESeo DreVisualizations BulkEdit Reference LocalContexts IframeEmbed; do
        docker compose exec -T php test ! -d "/var/www/html/modules/$amira_module"
    done
    echo "    DRESearch, DRE modules and DRE-theme absent (base image is generic)"
fi

log "Checking vocabulary import..."
docker compose logs php | grep -E '\[(OK|SKIP)\].*(FaBiO|fabio)'
if [[ "$variant" == "amira" ]]; then
    docker compose logs php | grep -E '\[(OK|SKIP)\].*DRE\b'
    echo "    dre vocabulary imported (overlay manifest picked up)"
else
    ! docker compose logs php | grep -E '\[(OK|SKIP)\].*DRE\b'
    echo "    dre vocabulary not present in base"
fi

if [[ "$variant" == "base" ]]; then
    log "Testing backup and destructive restore round trip..."
    backup_dir=$(mktemp -d -t omeka-smoke-backup.XXXXXX)
    docker compose exec -T php sh -eu -c \
        'printf %s ci-file-marker > /var/www/html/files/ci-backup-marker.txt'
    docker compose exec -T db sh -eu -c '
        exec mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e \
            "DROP TABLE IF EXISTS ci_backup_probe; CREATE TABLE ci_backup_probe (value VARCHAR(32) NOT NULL); INSERT INTO ci_backup_probe VALUES ('\''ci-db-marker'\'');"
    '

    bash scripts/backup.sh "$backup_dir"
    [[ "$(stat -c '%a' "$backup_dir")" == "700" ]]
    [[ "$(stat -c '%a' "$backup_dir/.env")" == "600" ]]
    [[ "$(stat -c '%a' "$backup_dir/local.config.php")" == "600" ]]
    grep -Fxq 'omeka-docker-backup-v2' "$backup_dir/BACKUP_FORMAT"
    grep -Fxq 'layout=immutable' "$backup_dir/BACKUP_FORMAT"
    [[ -f "$backup_dir/omeka_media.tar.gz" ]]
    [[ ! -e "$backup_dir/omeka_files.tar.gz" ]]
    (cd "$backup_dir" && sha256sum --check SHA256SUMS)

    docker compose exec -T php rm /var/www/html/files/ci-backup-marker.txt
    docker compose exec -T db sh -eu -c '
        exec mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e \
            "DROP TABLE ci_backup_probe;"
    '
    bash scripts/restore.sh --force "$backup_dir"
    wait_healthy db php web

    [[ "$(docker compose exec -T php cat /var/www/html/files/ci-backup-marker.txt)" == "ci-file-marker" ]]
    db_marker=$(docker compose exec -T db sh -eu -c '
        exec mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --batch --skip-column-names \
            "$MYSQL_DATABASE" -e "SELECT value FROM ci_backup_probe LIMIT 1;"
    ' | tr -d '\r')
    [[ "$db_marker" == "ci-db-marker" ]]
    code=$(probe "$url/")
    [[ "$code" =~ ^(200|30[123])$ ]]
    echo "    checksums, permissions, database, files, and restarted HTTP: OK"

    log "A/B test: rebuilding code while preserving database and media..."
    cp -R .github/fixtures/ImmutableProbe "$probe_module_dir"
    bash scripts/rebuild-code.sh --refresh

    docker compose exec -T php test -f /var/www/html/modules/ImmutableProbe/Module.php
    docker compose exec -T web test -f /var/www/html/modules/ImmutableProbe/Module.php
    php_hash=$(docker compose exec -T php sha256sum /var/www/html/modules/ImmutableProbe/Module.php | awk '{print $1}')
    web_hash=$(docker compose exec -T web sha256sum /var/www/html/modules/ImmutableProbe/Module.php | awk '{print $1}')
    [[ "$php_hash" == "$web_hash" ]]
    [[ "$(docker compose exec -T php cat /var/www/html/files/ci-backup-marker.txt)" == "ci-file-marker" ]]
    db_marker=$(docker compose exec -T db sh -eu -c '
        exec mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --batch --skip-column-names \
            "$MYSQL_DATABASE" -e "SELECT value FROM ci_backup_probe LIMIT 1;"
    ' | tr -d '\r')
    [[ "$db_marker" == "ci-db-marker" ]]
    docker compose exec -T php test -f /var/www/html/files/.immutable-layout-v1
    code=$(probe "$url/")
    [[ "$code" =~ ^(200|30[123])$ ]]
    echo "    new code is identical in PHP/nginx; database and media survived: OK"
fi

log "Smoke test passed ($variant)."
