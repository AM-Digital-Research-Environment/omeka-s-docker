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
    for setting in \
        "PHP_PM_MAX_CHILDREN=${PHP_PM_MAX_CHILDREN:-5}" \
        "PHP_PM_START_SERVERS=${PHP_PM_START_SERVERS:-2}" \
        "PHP_PM_MIN_SPARE_SERVERS=${PHP_PM_MIN_SPARE_SERVERS:-1}" \
        "PHP_PM_MAX_SPARE_SERVERS=${PHP_PM_MAX_SPARE_SERVERS:-3}" \
        "PHP_PM_MAX_REQUESTS=${PHP_PM_MAX_REQUESTS:-500}"; do
        value="${setting#*=}"
        if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
            log_error "${setting%%=*} must be a positive integer."
            exit 1
        fi
    done
    if [[ "${OMEKA_TZ:-UTC}" =~ [^A-Za-z0-9_+/:.-] ]]; then
        log_error "OMEKA_TZ contains invalid characters."
        exit 1
    fi

    cat > /run/php-fpm/zzz-omeka-pool.conf << FPMEOF
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
    # database.ini is a symlink into /run/omeka (tmpfs). Generate it directly:
    # omeka-s-cli deliberately requires the immutable config directory itself
    # to be writable, even when its output path is a symlink.
    php <<'PHP'
<?php
$values = [];
foreach (['MYSQL_USER', 'MYSQL_PASSWORD', 'MYSQL_DATABASE', 'MYSQL_HOST'] as $name) {
    $value = getenv($name);
    if ($value === false || $value === '') {
        fwrite(STDERR, "Missing required environment variable: {$name}\n");
        exit(1);
    }
    $values[$name] = addcslashes($value, '"');
}
$config = sprintf(
    "user = \"%s\"\npassword = \"%s\"\ndbname = \"%s\"\nhost = \"%s\"\nport = 3306\n",
    $values['MYSQL_USER'],
    $values['MYSQL_PASSWORD'],
    $values['MYSQL_DATABASE'],
    $values['MYSQL_HOST']
);
$path = '/run/omeka/database.ini';
if (file_put_contents($path, $config) === false || !chmod($path, 0600)) {
    fwrite(STDERR, "Could not create protected database configuration.\n");
    exit(1);
}
PHP
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

fpm_pool_config

# The DB config must be written first, as it is used during
# installation!
omeka_create_db_config
wait_for_db

# An installed database must never start against a media volume that isn't the
# one holding its files — an empty or wrongly-named volume would serve a site
# whose media has silently vanished. restore.sh writes this marker; fresh
# installs create it below, before initializing the database.
if omeka-s-cli core:status --base-path "${OMEKA_ROOT}" --is-installed; then
    if [[ ! -f "${OMEKA_ROOT}/files/.immutable-layout-v1" ]]; then
        log_error "Existing Omeka database detected, but the media volume carries"
        log_error "no layout marker — it is empty or is not the volume this"
        log_error "database belongs to. Refusing to start and serve a site with"
        log_error "no media. Check that omeka_media is mounted, or restore a"
        log_error "backup with: bash scripts/restore.sh <backup-directory>"
        exit 1
    fi
else
    touch "${OMEKA_ROOT}/files/.immutable-layout-v1"
fi

omeka_install
omeka_modules_install
omeka_import_vocabularies

exec "$@"
