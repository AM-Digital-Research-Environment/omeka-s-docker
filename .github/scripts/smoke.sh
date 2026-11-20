#!/usr/bin/env bash
# CI smoke test: boots the stack, waits for health, probes HTTP behaviour,
# and tears down (including volumes). Variants:
#
#   smoke.sh base      — generic template with its defaults, no admin env vars
#                        (the same path the one-click bootstrap produces).
#                        Modules/themes are admin-managed volumes here, so this
#                        checks seeding from the image, EasyAdmin's writability
#                        condition, live install, persistence across recreation,
#                        and the backup/restore round trip.
#   smoke.sh amira     — base + AMIRA overlay activated via COMPOSE_FILE in .env,
#                        admin env vars set, search profile on. The amira-mcp
#                        service itself is NOT built (external repo with a
#                        build-time data fetch); /mcp answering 502 instead of
#                        404 proves the overlay's nginx location is wired in.
#                        The curator profile stays off too, so /curator/mcp
#                        must answer 502 the same way.
#                        The sparql profile stays off, so /sparql must answer
#                        its own 503 and the rest of the site must not care.
#   smoke.sh immutable — base + compose.immutable.yml: modules/themes back in
#                        the image layer. Checks that nothing under the document
#                        root is writable, plus the backup/restore round trip
#                        and the A/B image rebuild on retained volumes.
#   smoke.sh secrets   — base + compose.secrets.yml with the search profile:
#                        all four credentials come from files in ./secrets
#                        (special characters, trailing newline, admin
#                        password included). Checks that no plain value is in
#                        any container configuration or in php-fpm's
#                        environment where it is not needed, that db, php and
#                        typesense authenticate with the files, and that
#                        backup/restore carries the secret files.
#   smoke.sh tls       — base + compose.tls.yml with CADDY_TLS=internal (Caddy's
#                        own CA, so no DNS or ACME). Every probe goes through
#                        Caddy on ports 80/443 (curl --resolve -k): HTTP
#                        redirects to HTTPS, exactly one HSTS header, the
#                        session cookie is Secure, Omeka builds https:// URLs
#                        (nginx trusts Caddy's X-Forwarded-Proto), and
#                        backup/restore carries the certificates in caddy_data.
#
# Honours SMOKE_HTTP_PORT (default 80) for hosts where 80 is taken; the tls
# variant always needs 80 and 443.

set -Eeuo pipefail

variant="${1:?usage: smoke.sh base|amira|immutable|secrets|tls}"
port="${SMOKE_HTTP_PORT:-80}"
url="http://127.0.0.1:${port}"
tls_host=ci.example.org
if [[ "$variant" == tls ]]; then
    # Caddy answers only for SERVER_NAME, with a certificate from its internal
    # CA: point the name at this machine and accept that certificate. Every
    # curl below, probe() included, then goes through Caddy.
    url="https://${tls_host}"
    curl() { command curl --resolve "${tls_host}:443:127.0.0.1" --resolve "${tls_host}:80:127.0.0.1" -k "$@"; }
fi
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
        # Only ever created by this script (the guard below refuses to run
        # over an existing one).
        [[ "$variant" != secrets ]] || rm -rf -- secrets
    fi
    exit "$status"
}
# Guard before installing cleanup: even a refused run must not delete a real
# restored configuration or a developer's module. Use a disposable checkout.
if [[ -e .env || -e secrets || -e "$probe_module_dir" || -e _docker/restored-local.config.php ]]; then
    echo "Refusing to run smoke tests over existing environment/configuration/fixtures. Use a clean, disposable checkout." >&2
    exit 1
fi
trap cleanup EXIT

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
    immutable)
        cat > .env <<EOF
COMPOSE_PROJECT_NAME=omeka-smoke-immutable-${GITHUB_RUN_ID:-$$}
MYSQL_DATABASE=omeka_ci
MYSQL_USER=omeka_ci
MYSQL_PASSWORD="ci-mysql-password-with-special-#=chars"
NGINX_PORT=${port}
COMPOSE_FILE=docker-compose.yml:compose.immutable.yml
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
    secrets)
        cat > .env <<EOF
COMPOSE_PROJECT_NAME=omeka-smoke-secrets-${GITHUB_RUN_ID:-$$}
MYSQL_DATABASE=omeka_ci
MYSQL_USER=omeka_ci
NGINX_PORT=${port}
COMPOSE_FILE=docker-compose.yml:compose.secrets.yml
COMPOSE_PROFILES=search
SECRETS_DIR=./secrets
OMEKA_ADMIN_EMAIL=admin@example.com
OMEKA_ADMIN_USERNAME=ci-admin
OMEKA_TITLE=CI Smoke Test
EOF
        # As documented in compose.secrets.yml: 0700 directory, 0644 files,
        # read by uid 999 (db), 33 (php) and 10002 (typesense).
        install -d -m 0700 secrets
        (
            umask 022
            # Trailing newline on purpose: every reader must strip it.
            printf '%s\n' 'ci-secret-db-password-#=chars' > secrets/mysql_password
            printf '%s' 'Y2ktc2VjcmV0LWtleS1mb3Itb21la2Etc21va2UtdGVzdA==' > secrets/omeka_secret_key
            printf '%s' 'ci-secret-typesense-key' > secrets/typesense_api_key
            printf '%s' 'ci-secret-admin-password' > secrets/omeka_admin_password
        )
        ;;
    tls)
        # No NGINX_PORT: the overlay stops publishing nginx; Caddy takes 80/443.
        cat > .env <<EOF
COMPOSE_PROJECT_NAME=omeka-smoke-tls-${GITHUB_RUN_ID:-$$}
MYSQL_DATABASE=omeka_ci
MYSQL_USER=omeka_ci
MYSQL_PASSWORD="ci-mysql-password-with-special-#=chars"
COMPOSE_FILE=docker-compose.yml:compose.tls.yml
SERVER_NAME=${tls_host}
CADDY_TLS=internal
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

# Caddy is healthy once its admin API answers; the certificate (internal CA,
# no network involved) follows within moments.
wait_https() {
    local tries
    for tries in $(seq 30); do
        [[ "$(curl -s -o /dev/null -w '%{http_code}' "$url/application/asset/css/style.css")" != 200 ]] || return 0
        sleep 2
    done
    echo "HTTPS did not answer through Caddy after $tries tries" >&2
    return 1
}

log "Waiting for services to become healthy..."
if [[ "$variant" == "amira" || "$variant" == "secrets" ]]; then
    wait_healthy db php web typesense
elif [[ "$variant" == "tls" ]]; then
    wait_healthy db php web caddy
    wait_https
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
if [[ "$variant" == "amira" || "$variant" == "secrets" ]]; then
    cid=$(docker compose ps -q typesense)
    docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$cid" | grep -F 'no-new-privileges:true'
    docker inspect -f '{{json .HostConfig.CapDrop}}' "$cid" | grep -F 'ALL'
    [[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$cid")" == "true" ]]
    [[ -z "$(docker port "$cid")" ]]
fi
if [[ "$variant" == "tls" ]]; then
    cid=$(docker compose ps -q caddy)
    docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$cid" | grep -F 'no-new-privileges:true'
    [[ "$(docker inspect -f '{{json .HostConfig.CapDrop}}' "$cid")" == '["ALL"]' ]]
    [[ "$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$cid")" == null ]]
    [[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$cid")" == "true" ]]
    # Only Caddy faces the host; nginx is reached over the frontend network.
    [[ -z "$(docker port "$(docker compose ps -q web)")" ]]
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
if [[ "$variant" == "immutable" ]]; then
    docker compose exec -T php sh -eu -c '
        ! touch /var/www/html/modules/.ci-must-not-write
        ! touch /var/www/html/themes/.ci-must-not-write
    '
    echo "    modules/themes are immutable image content: OK"
fi
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
    /files/probe.PHP
    /files/probe.phtml
    /files/probe.phar
    /files/probe.php/photo.jpg
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
curl -fsSI "$url/application/asset/css/style.css" | grep -Fi 'max-age=0, must-revalidate'
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

log "Checking the session cookie flags and first-install summary..."
# Defaults: plain HTTP, so not Secure, but SameSite=Lax from the FPM pool.
# compose.tls.yml serves HTTPS only and defaults the cookie to Secure.
cookie=$(curl -s -D - -o /dev/null "$url/login" | grep -i '^set-cookie:' | head -n 1)
echo "    ${cookie%%=*}=… $(grep -oiE '(; *(httponly|secure|samesite=[a-z]+))+' <<< "$cookie" || true)"
grep -qi 'samesite=lax' <<< "$cookie"
grep -qi 'httponly' <<< "$cookie"
if [[ "$variant" == "tls" ]]; then
    grep -qiE ';[[:space:]]*secure' <<< "$cookie"
# `! cmd` never trips set -e, so negative checks use an explicit if.
elif grep -qiE ';[[:space:]]*secure' <<< "$cookie"; then
    echo "Session cookie is Secure although OMEKA_SESSION_COOKIE_SECURE defaults to false." >&2
    exit 1
fi
php_log=$(docker compose logs --no-color php)
grep -qF 'Omeka S is installed and ready.' <<< "$php_log"
if [[ "$variant" == "amira" ]]; then
    grep -qF 'Admin user created: admin@example.com' <<< "$php_log"
    if grep -qF 'ci-admin-password' <<< "$php_log"; then
        echo "SECURITY: the admin password appeared in the php log!" >&2
        exit 1
    fi
else
    # No admin account configured: the installer must not fall back to
    # omeka-s-cli's published default (admin@example.com / "admin").
    grep -qF 'Generated admin password: ' <<< "$php_log"
fi
if [[ "$variant" == "secrets" ]]; then
    grep -qF 'Admin user created: admin@example.com' <<< "$php_log"
    if grep -qF 'ci-secret-admin-password' <<< "$php_log"; then
        echo "SECURITY: the admin password appeared in the php log!" >&2
        exit 1
    fi
fi

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

if [[ "$variant" == "amira" ]]; then
    log "Probing /curator/mcp routing..."
    # Location present, the curator profile off: 502, and the site unaffected.
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Bearer smoke' "$url/curator/mcp")
    echo "    POST /curator/mcp -> $code"
    [[ "$code" == "502" ]]
fi

log "Checking Omeka API keys stay out of the access log..."
# Omeka reads API keys from the query string; nginx must log them redacted.
# Hyphenated values, so check-committed-secrets.sh does not take them for keys.
code=$(probe "$url/api/items?key_identity=smoke-identity-value&key_credential=smoke-credential-value&per_page=1")
echo "    GET /api/items?key_identity=…&key_credential=… -> $code"
sleep 1
# Access-log lines only (they start with the client address). nginx's error
# log cannot be reformatted, so an upstream error on a keyed request would
# still quote the key there: see "API keys in the logs" in
# deploy/amira/README.md.
access_log=$(docker compose logs --no-color --no-log-prefix web 2>/dev/null | grep -E '^[0-9a-f.:]+ - ' || true)
grep -qF 'GET /api/items?key_identity=[REDACTED]&key_credential=[REDACTED]&per_page=1 HTTP/1.1' <<< "$access_log"
if grep -qE 'smoke-(identity|credential)-value' <<< "$access_log"; then
    echo "SECURITY: an API key reached the access log!" >&2
    exit 1
fi

log "Probing /sparql routing..."
code=$(probe "$url/sparql")
echo "    GET /sparql -> $code"
if [[ "$variant" == "amira" ]]; then
    # Location and limit zones loaded; the opt-in service is not running.
    [[ "$code" == "503" ]]
    headers=$(curl -sS -D - -o /dev/null "$url/sparql")
    grep -qi '^access-control-allow-origin: \*' <<< "$headers"
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS -H 'Origin: https://example.org' \
        -H 'Access-Control-Request-Method: POST' "$url/sparql")" == "204" ]]
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$url/sparql")" == "405" ]]
    # A browser opening the endpoint is sent to the page that explains it,
    # by a relative redirect, whether or not the service runs.
    redirect=$(curl -sS -D - -o /dev/null -H 'Accept: text/html' "$url/sparql")
    grep -q '^HTTP/[0-9.]* 303' <<< "$redirect"
    grep -qi '^location: /s/amira/page/linked-open-data' <<< "$redirect"
    # The service description's rewrite target is internal.
    [[ "$(probe "$url/sparql-service-description")" == "404" ]]
else
    [[ "$code" != "503" ]]
fi

if [[ "$variant" == "amira" ]]; then
    log "Probing the dre: vocabulary at /ontology/dre..."
    # Negotiated by Accept in nginx: browsers get HTML, RDF clients what they
    # name, and no preference gets Turtle. Each answer names its document.
    for pair in "text/html,*/*;q=0.8|text/html|dre.html" "text/turtle|text/turtle|dre.ttl" \
        "application/rdf+xml|application/rdf+xml|dre.rdf" \
        "application/ld+json|application/ld+json|dre.jsonld" "*/*|text/turtle|dre.ttl"; do
        IFS='|' read -r accept type document <<< "$pair"
        headers=$(curl -fsS -D - -o /dev/null -H "Accept: $accept" "$url/ontology/dre")
        echo "$headers" | grep -qi "^content-type: $type"
        echo "$headers" | grep -qi "^content-location: /ontology/$document"
        echo "$headers" | grep -qi '^vary: Accept\b'
    done
    curl -fsS "$url/ontology/dre.ttl" | grep -F '<https://data.africamultiple.uni-bayreuth.de/ontology/dre#>'
    # Only the four generated documents are served from that directory.
    [[ "$(probe "$url/ontology/dre.json")" == "404" ]]
    echo "    /ontology/dre negotiates HTML, Turtle, RDF/XML and JSON-LD"
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
    for amira_module in DRESeo DreVisualizations BulkEdit Reference LocalContexts; do
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
    log "Checking admin-managed modules and themes (the default)..."
    # The exact condition EasyAdmin tests before enabling module/theme
    # management from the admin UI.
    docker compose exec -T php php -r 'exit(is_writable("/var/www/html/modules") && is_writable("/var/www/html/themes") ? 0 : 1);'
    # First boot seeded the volumes from the php image: baked defaults appear.
    docker compose exec -T php test -d /var/www/html/modules/EasyAdmin
    docker compose exec -T php test -d /var/www/html/themes/Freedom
    # nginx shares the same volumes read-only.
    docker compose exec -T web test -d /var/www/html/modules/EasyAdmin
    docker compose exec -T web sh -eu -c '! touch /var/www/html/modules/.ci-must-not-write'
    docker compose exec -T web sh -eu -c '! touch /var/www/html/themes/.ci-must-not-write'
    echo "    modules/themes writable for PHP, read-only for nginx, seeded from image: OK"

    log "Installing a module live (no image rebuild)..."
    tar -cf - -C .github/fixtures ImmutableProbe \
        | docker compose exec -T php tar -xf - -C /var/www/html/modules
    docker compose exec -T php test -f /var/www/html/modules/ImmutableProbe/Module.php
    docker compose exec -T web test -f /var/www/html/modules/ImmutableProbe/Module.php
    php_hash=$(docker compose exec -T php sha256sum /var/www/html/modules/ImmutableProbe/Module.php | awk '{print $1}')
    web_hash=$(docker compose exec -T web sha256sum /var/www/html/modules/ImmutableProbe/Module.php | awk '{print $1}')
    [[ "$php_hash" == "$web_hash" ]]
    echo "    module visible in PHP and nginx immediately, byte-identical: OK"

    log "Downloading a module live with omeka-s-cli..."
    docker compose exec -T php omeka-s-cli module:download --base-path /var/www/html CSSEditor
    docker compose exec -T php test -d /var/www/html/modules/CSSEditor
    docker compose exec -T web test -d /var/www/html/modules/CSSEditor
    echo "    omeka-s-cli writes into the live modules volume: OK"

    log "Checking live modules survive container recreation..."
    docker compose up -d --force-recreate php
    wait_healthy php web
    docker compose exec -T php test -f /var/www/html/modules/ImmutableProbe/Module.php
    docker compose exec -T php test -d /var/www/html/modules/CSSEditor
    code=$(probe "$url/")
    [[ "$code" =~ ^(200|30[123])$ ]]
    echo "    live-managed modules persisted across recreation: OK"

    log "Testing backup and destructive restore of live-managed extensions..."
    backup_dir=$(mktemp -d -t omeka-smoke-backup.XXXXXX)
    bash scripts/backup.sh "$backup_dir"
    [[ -f "$backup_dir/omeka_modules.tar.gz" ]]
    [[ -f "$backup_dir/omeka_themes.tar.gz" ]]
    (cd "$backup_dir" && sha256sum --check SHA256SUMS)

    docker compose exec -T php rm -rf /var/www/html/modules/ImmutableProbe /var/www/html/modules/CSSEditor
    docker compose exec -T php test ! -d /var/www/html/modules/ImmutableProbe
    bash scripts/restore.sh --force "$backup_dir"
    wait_healthy db php web
    docker compose exec -T php test -f /var/www/html/modules/ImmutableProbe/Module.php
    docker compose exec -T php test -d /var/www/html/modules/CSSEditor
    code=$(probe "$url/")
    [[ "$code" =~ ^(200|30[123])$ ]]
    echo "    backup includes module/theme volumes; restore brought them back: OK"
fi

if [[ "$variant" == "secrets" ]]; then
    log "Checking file-based secrets (compose.secrets.yml)..."
    secret_values=(ci-secret-db-password ci-secret-typesense-key ci-secret-admin-password
        Y2ktc2VjcmV0LWtleS1mb3Itb21la2Etc21va2UtdGVzdA==)
    for svc in php db typesense; do
        cid=$(docker compose ps -q "$svc")
        config_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid")
        for name in MYSQL_PASSWORD OMEKA_SECRET_KEY TYPESENSE_API_KEY OMEKA_ADMIN_PASSWORD; do
            if grep -q "^${name}=" <<< "$config_env"; then
                echo "SECURITY: $svc configuration still carries $name" >&2
                exit 1
            fi
        done
        for value in "${secret_values[@]}"; do
            if grep -qF -- "$value" <<< "$config_env"; then
                echo "SECURITY: a secret value is visible in docker inspect of $svc" >&2
                exit 1
            fi
        done
    done
    # php-fpm (PID 1) keeps only what Omeka and DRESearch read with getenv():
    # the database and admin passwords must not be in its environment.
    fpm_env=$(docker compose exec -T php sh -c 'tr "\0" "\n" < /proc/1/environ' | tr -d '\r')
    for name in MYSQL_PASSWORD OMEKA_ADMIN_PASSWORD; do
        if grep -q "^${name}=" <<< "$fpm_env"; then
            echo "SECURITY: $name is in php-fpm's environment" >&2
            exit 1
        fi
    done
    grep -qx 'OMEKA_SECRET_KEY=Y2ktc2VjcmV0LWtleS1mb3Itb21la2Etc21va2UtdGVzdA==' <<< "$fpm_env"
    grep -qx 'TYPESENSE_API_KEY=ci-secret-typesense-key' <<< "$fpm_env"
    # The key Typesense loaded from its file is the one php sends.
    docker compose exec -T -e KEY=ci-secret-typesense-key php php -r '
        $context = stream_context_create(["http" => ["header" => "X-TYPESENSE-API-KEY: " . getenv("KEY") . "\r\n", "ignore_errors" => true]]);
        file_get_contents("http://typesense:8108/collections", false, $context);
        exit(str_contains($http_response_header[0] ?? "", " 200 ") ? 0 : 1);
    '
    # The backup/restore helpers authenticate from the db container's file.
    docker compose exec -T db sh -eu -c '
        exec mysql -u"$MYSQL_USER" -p"$(cat "$MYSQL_PASSWORD_FILE")" "$MYSQL_DATABASE" -e "SELECT 1"' >/dev/null
    echo "    no plain secret in any container configuration; files authenticate db, php and typesense: OK"

    log "Testing backup and restore of the secret files..."
    backup_dir=$(mktemp -d -t omeka-smoke-backup.XXXXXX)
    bash scripts/backup.sh "$backup_dir"
    [[ "$(stat -c '%a' "$backup_dir/secrets")" == "700" ]]
    for name in mysql_password omeka_secret_key typesense_api_key omeka_admin_password; do
        [[ "$(stat -c '%a' "$backup_dir/secrets/$name")" == "600" ]]
        cmp -s "secrets/$name" "$backup_dir/secrets/$name"
    done
    grep -q ' secrets/omeka_secret_key$' "$backup_dir/SHA256SUMS"
    (cd "$backup_dir" && sha256sum --check SHA256SUMS)
    # A lost key file is put back from the backup with the documented mode.
    rm secrets/omeka_secret_key
    bash scripts/restore.sh --force "$backup_dir"
    [[ "$(stat -c '%a' secrets/omeka_secret_key)" == "644" ]]
    cmp -s secrets/omeka_secret_key "$backup_dir/secrets/omeka_secret_key"
    wait_healthy db php web typesense
    code=$(probe "$url/")
    [[ "$code" =~ ^(200|30[123])$ ]]
    echo "    backup carries the secret files (0600); restore puts a missing one back (0644): OK"
fi

if [[ "$variant" == "tls" ]]; then
    log "Checking the bundled HTTPS edge (compose.tls.yml)..."
    redirect=$(curl -sS -D - -o /dev/null "http://${tls_host}/admin?x=1")
    grep -qE '^HTTP/[0-9.]+ 30[18]' <<< "$redirect"
    grep -qi "^location: https://${tls_host}/admin?x=1" <<< "$redirect"
    headers=$(curl -sS -D - -o /dev/null "$url/application/asset/css/style.css")
    grep -qE '^HTTP/[0-9.]+ 200' <<< "$headers"
    # Caddy sets it; nginx's NGINX_HSTS_MAX_AGE stays 0. One header, not two.
    [[ "$(grep -ci '^strict-transport-security:' <<< "$headers")" == 1 ]]
    grep -qi '^strict-transport-security: max-age=31536000' <<< "$headers"
    # Omeka builds absolute links from what nginx passes on: https only if
    # nginx trusted Caddy's X-Forwarded-Proto (NGINX_TRUSTED_PROXY_CIDR).
    curl -fsS "$url/api/vocabularies?per_page=1" \
        | jq -e --arg prefix "https://${tls_host}/" '.[0]["@id"] | startswith($prefix)'
    echo "    HTTP->HTTPS redirect, one HSTS header, Secure cookie, https:// URLs from Omeka: OK"

    log "Testing backup and restore of the certificates (caddy_data)..."
    cert_fingerprint() {
        openssl s_client -connect 127.0.0.1:443 -servername "$tls_host" < /dev/null 2>/dev/null \
            | openssl x509 -noout -fingerprint -sha256
    }
    before=$(cert_fingerprint)
    [[ -n "$before" ]]
    backup_dir=$(mktemp -d -t omeka-smoke-backup.XXXXXX)
    bash scripts/backup.sh "$backup_dir"
    [[ -f "$backup_dir/caddy_data.tar.gz" ]]
    grep -q ' caddy_data.tar.gz$' "$backup_dir/SHA256SUMS"
    (cd "$backup_dir" && sha256sum --check SHA256SUMS)
    # Lose the certificates: without the restore Caddy would mint new ones
    # from a new internal CA, so an identical fingerprint proves the restore.
    docker compose exec -T caddy rm -rf /data/caddy
    bash scripts/restore.sh --force "$backup_dir"
    wait_healthy db php web caddy
    wait_https
    [[ "$(cert_fingerprint)" == "$before" ]]
    echo "    certificates backed up and restored, not re-issued: OK"
fi

if [[ "$variant" == "immutable" ]]; then
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
    # The web image carries only what nginx may serve (asset/ trees), so give
    # the probe an asset to compare across both images.
    mkdir -p "$probe_module_dir/asset/css"
    printf '/* smoke %s */\n' "${GITHUB_RUN_ID:-$$}" > "$probe_module_dir/asset/css/probe.css"
    bash scripts/rebuild-code.sh --refresh

    docker compose exec -T php test -f /var/www/html/modules/ImmutableProbe/Module.php
    probe_asset=/var/www/html/modules/ImmutableProbe/asset/css/probe.css
    php_hash=$(docker compose exec -T php sha256sum "$probe_asset" | awk '{print $1}')
    web_hash=$(docker compose exec -T web sha256sum "$probe_asset" | awk '{print $1}')
    [[ "$php_hash" == "$web_hash" ]]
    # ...and no PHP source: the web image must not ship code nginx never runs.
    docker compose exec -T web test ! -e /var/www/html/modules/ImmutableProbe/Module.php
    docker compose exec -T web test ! -e /var/www/html/vendor
    docker compose exec -T web test ! -e /var/www/html/application/src
    [[ "$(probe "$url/modules/ImmutableProbe/asset/css/probe.css")" == "200" ]]
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
