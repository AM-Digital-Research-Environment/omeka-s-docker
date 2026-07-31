#!/usr/bin/env bash
set -Eeuo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo >&2 -e "${GREEN}[INFO]${NC} ${1-}"; }
log_warn() { echo >&2 -e "${YELLOW}[WARN]${NC} ${1-}"; }
log_error() { echo >&2 -e "${RED}[ERROR]${NC} ${1-}"; }
log_step() { echo >&2 -e "${BLUE}[STEP]${NC} ${1-}"; }

# Fail early if the omeka-s-cli isn't found - we can't continue without it, but it's unlikely that it's missing.
if ! command -v omeka-s-cli &>/dev/null; then
    log_error "omeka-s-cli not found!"
    log_error "omeka-s-cli should be installed during the container build of the php container."
    log_error "Please check the build logs for failures."
    exit 1
fi

OMEKA_ROOT="/var/www/html"

fpm_pool_config() {
    # Generate PHP-FPM pool configuration (supports runtime tuning via
    # env vars)
    log_step "Configuring PHP-FPM pool..."
    cat > /usr/local/etc/php-fpm.d/zzz-omeka-pool.conf << FPMEOF
[www]
pm = dynamic
pm.max_children = ${PHP_PM_MAX_CHILDREN:-5}
pm.start_servers = ${PHP_PM_START_SERVERS:-2}
pm.min_spare_servers = ${PHP_PM_MIN_SPARE_SERVERS:-1}
pm.max_spare_servers = ${PHP_PM_MAX_SPARE_SERVERS:-3}
pm.max_requests = ${PHP_PM_MAX_REQUESTS:-500}
pm.process_idle_timeout = 10s
request_terminate_timeout = 300s
php_admin_value[date.timezone] = ${OMEKA_TZ:-UTC}
FPMEOF
    log_info "PHP-FPM pool: max_children=${PHP_PM_MAX_CHILDREN:-5}, start=${PHP_PM_START_SERVERS:-2}, min_spare=${PHP_PM_MIN_SPARE_SERVERS:-1}, max_spare=${PHP_PM_MAX_SPARE_SERVERS:-3}"
}

omeka_create_db_config() {
    log_step "Creating database configuration..."

    omeka-s-cli config:create-db-ini \
                --base-path "${OMEKA_ROOT}" \
                --username "${MYSQL_USER}" \
                --password "${MYSQL_PASSWORD}" \
                --dbname "${MYSQL_DATABASE}" \
                --host "${MYSQL_HOST}"
    # The shared document-root volume is also mounted read-only by nginx. Keep
    # database credentials readable only by the www-data user running PHP.
    chmod 600 "${OMEKA_ROOT}/config/database.ini"
}

wait_for_db() {
    # Belt-and-braces on top of the compose service_healthy dependency: never
    # run the installer/migrations against a database that isn't accepting
    # TCP connections yet (e.g. after a db restart while php stayed up).
    log_step "Waiting for the database to accept connections..."
    local tries=0
    until php -r 'new mysqli(getenv("MYSQL_HOST"), getenv("MYSQL_USER"), getenv("MYSQL_PASSWORD"), getenv("MYSQL_DATABASE"));' >/dev/null 2>&1; do
        tries=$((tries + 1))
        if (( tries >= 30 )); then
            log_error "Database not reachable after ${tries} attempts, giving up."
            exit 1
        fi
        sleep 2
    done
    log_info "Database is up."
}

omeka_install() {
    # Warn when using "latest" — the resolved version has not been tested against this image
    if [[ "$OMEKA_VERSION" == "latest" ]]; then
        log_warn "OMEKA_VERSION=latest — the resolved version may not be tested with this image"
    fi

    if ! omeka-s-cli core:status --base-path "${OMEKA_ROOT}" --is-installed; then
        log_step "Omeka S is not yet installed. Installing..."
        if [[ -n "${OMEKA_ADMIN_EMAIL:-}" && -n "${OMEKA_ADMIN_PASSWORD:-}" && -n "${OMEKA_ADMIN_USERNAME:-}" ]]; then
            log_info "Creating admin user"
            omeka-s-cli core:install \
                        --base-path "${OMEKA_ROOT}" \
                        --locale "${OMEKA_LOCALE}" \
                        --time-zone "${OMEKA_TZ:-UTC}" \
                        --title "${OMEKA_TITLE}" \
                        --admin-email "${OMEKA_ADMIN_EMAIL}" \
                        --admin-name "${OMEKA_ADMIN_USERNAME}" \
                        --admin-password "${OMEKA_ADMIN_PASSWORD}"
        else
            log_info "Will not create admin user"
            omeka-s-cli core:install \
                        --base-path "${OMEKA_ROOT}" \
                        --locale "${OMEKA_LOCALE}" \
                        --time-zone "${OMEKA_TZ:-UTC}" \
                        --title "${OMEKA_TITLE}"
        fi
    else
        log_info "Omeka S is already installed. Good!"
    fi
}

module_name_from_entry() {
    # Extract a candidate module name from an EXTRA_MODULES entry.
    # Plain names pass through unchanged.  For URLs, we take the
    # basename, strip archive extensions, and strip a trailing version
    # suffix (e.g. "CSVImport-3.0.0.zip" → "CSVImport").
    local entry="$1"
    if [[ "$entry" == *"://"* || "$entry" == gh:* ]]; then
        local base
        base=$(basename "$entry")
        base="${base%.zip}"
        base="${base%.tar.gz}"
        base="${base%.git}"
        # Strip trailing version: -3.0.0, -v1.2.3, etc.
        base="${base%%-[vV][0-9]*}"
        base="${base%%-[0-9]*}"
        [[ -n "$base" ]] && echo "$base" || echo "$entry"
    else
        echo "$entry"
    fi
}

module_dir_exists() {
    # Case-insensitive check: does a directory matching the given name
    # already exist under $OMEKA_ROOT/modules/?
    local name="${1,,}"
    for d in "${OMEKA_ROOT}"/modules/*/; do
        [[ -d "$d" ]] || continue
        [[ "${d##*/}" == "/" ]] && continue
        local base
        base=$(basename "$d")
        [[ "${base,,}" == "$name" ]] && return 0
    done
    return 1
}

omeka_extra_modules_download() {
    # Download extra modules from the EXTRA_MODULES env var
    # (comma-separated)
    if [[ -n "${EXTRA_MODULES:-}" ]]; then
        log_step "Downloading extra modules..."
        IFS=',' read -ra EXTRA_MODULE_LIST <<< "$EXTRA_MODULES"
        for entry in "${EXTRA_MODULE_LIST[@]}"; do
            entry=$(echo "$entry" | xargs)
            [[ -z "$entry" ]] && continue
            local mod_name
            mod_name=$(module_name_from_entry "$entry")
            if module_dir_exists "$mod_name"; then
                log_info "Module ${mod_name} is already present, skipping"
                continue
            fi
            log_step "Downloading $entry"
            omeka-s-cli module:download \
                        --base-path "$OMEKA_ROOT" \
                        "$entry" \
                || log_error "Failed to download extra module: $entry"
        done
    else
        log_info "No EXTRA_MODULES to download."
    fi
}

omeka_modules_install() {
    log_step "Installing modules (EXTRA and DEFAULT)..."
    for module_dir in "${OMEKA_ROOT}"/modules/*/; do
        [[ -d "$module_dir" ]] || continue
        mod=$(basename "$module_dir")
        omeka-s-cli module:install \
                    --base-path "$OMEKA_ROOT" \
                    "$mod" \
            || log_error "Failed to install module $mod"
    done
}

omeka_extra_themes_download() {
    # Download extra themes from the EXTRA_THEMES env var
    # (comma-separated)
    if [[ -n "${EXTRA_THEMES:-}" ]]; then
        log_step "Downloading extra themes..."
        IFS=',' read -ra EXTRA_THEME_LIST <<< "$EXTRA_THEMES"
        for entry in "${EXTRA_THEME_LIST[@]}"; do
            entry=$(echo "$entry" | xargs)
            [[ -z "$entry" ]] && continue
            log_step "Downloading $entry"
            omeka-s-cli theme:download \
                        --base-path "$OMEKA_ROOT" \
                        "$entry" \
                || log_error "Failed to download extra theme: $entry"
        done
    else
        log_info "No EXTRA_THEMES to download."
    fi
}

omeka_extra_config() {
    log_step "Setting global config for Omeka..."

    log_step "Setting thumbnailer to Imagick"
    sed -i "s/Thumbnailer\\\ImageMagick/Thumbnailer\\\Imagick/g" \
        "${OMEKA_ROOT}/config/local.config.php"

    # Self-host jQuery instead of code.jquery.com. Omeka core ships
    # 'assets' => ['use_externals' => true] which rewrites the local jQuery
    # asset URL to a CDN, adding a render-blocking DNS+TCP+TLS round-trip on
    # the critical path (the CDN is not preconnected). Disabling externals
    # serves Omeka's bundled application/asset/vendor/jquery/jquery.min.js
    # same-origin (HTTP/2 reuse) and immutable-cached by nginx. Idempotent.
    log_step "Self-hosting jQuery (disabling external asset CDNs)"
    if ! grep -q "use_externals" "${OMEKA_ROOT}/config/local.config.php"; then
        sed -i "/^return \[/a\\    'assets' => ['use_externals' => false]," \
            "${OMEKA_ROOT}/config/local.config.php"
    fi
}

omeka_import_vocabularies() {
    local vocab_dir="/usr/local/share/omeka-vocabs"
    local script="${vocab_dir}/import-vocabularies.php"
    if [[ ! -f "$script" ]]; then
        log_info "No vocabulary import script found, skipping."
        return
    fi
    log_step "Importing custom vocabularies..."
    php "$script" "$vocab_dir" "$OMEKA_ROOT" || log_error "Vocabulary import failed"
}

omeka_iiif_install() {
    # Install IIIF modules when ENABLE_IIIF=true
    if [[ "${ENABLE_IIIF:-false}" != "true" ]]; then
        return
    fi

    log_step "Installing IIIF modules..."

    local iiif_modules=(
        "gh:Daniel-KM/Omeka-S-module-IiifServer"
        "gh:Daniel-KM/Omeka-S-module-ImageServer"
        "gh:Daniel-KM/Omeka-S-module-Mirador"
    )

    for mod in "${iiif_modules[@]}"; do
        local mod_name
        mod_name=$(basename "$mod")
        mod_name="${mod_name#Omeka-S-module-}"
        if [[ -d "${OMEKA_ROOT}/modules/${mod_name}" ]]; then
            log_info "Module ${mod_name} is already present, skipping"
            continue
        fi
        log_step "Downloading ${mod_name}"
        omeka-s-cli module:download --base-path "$OMEKA_ROOT" "$mod" \
            || log_error "Failed to download IIIF module: ${mod_name}"
    done
}

fpm_pool_config

# The DB config must be written first, as it is used during
# installation!
omeka_create_db_config
wait_for_db
omeka_install
omeka_extra_config

omeka_iiif_install
omeka_extra_modules_download
omeka_modules_install
omeka_import_vocabularies

omeka_extra_themes_download

exec "$@"
