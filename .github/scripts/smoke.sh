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

log() { printf '\n==> %s\n' "$*"; }

on_error() {
    log "FAILURE — service state and logs:"
    docker compose ps || true
    docker compose logs --tail 200 || true
}
trap on_error ERR

# Never clobber a developer's real .env.
if [[ -f .env && "${CI:-}" != "true" ]]; then
    echo "Refusing to overwrite an existing .env outside CI." >&2
    exit 1
fi

case "$variant" in
    base)
        cat > .env <<EOF
MYSQL_PASSWORD=ci-mysql-password
NGINX_PORT=${port}
EOF
        ;;
    amira)
        cat > .env <<EOF
MYSQL_PASSWORD=ci-mysql-password
NGINX_PORT=${port}
COMPOSE_FILE=docker-compose.yml:compose.amira.yml
COMPOSE_PROFILES=search
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

log "Booting stack ($variant)..."
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
    echo "    DRESearch present (overlay bakes DRE modules)"
else
    docker compose exec -T php test ! -d /var/www/html/modules/DRESearch
    echo "    DRESearch absent (base image is generic)"
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

log "Tearing down ($variant)..."
docker compose down -v --remove-orphans
rm -f .env

log "Smoke test passed ($variant)."
