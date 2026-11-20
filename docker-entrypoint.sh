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
    local maximum="${PHP_PM_MAX_CHILDREN:-5}" start="${PHP_PM_START_SERVERS:-2}"
    local minimum_spare="${PHP_PM_MIN_SPARE_SERVERS:-1}" maximum_spare="${PHP_PM_MAX_SPARE_SERVERS:-3}"
    if (( minimum_spare > start || start > maximum_spare || maximum_spare > maximum )); then
        log_error "PHP-FPM requires min_spare <= start_servers <= max_spare <= max_children."
        exit 1
    fi
    if [[ "${OMEKA_TZ:-UTC}" =~ [^A-Za-z0-9_+/:.-] ]]; then
        log_error "OMEKA_TZ contains invalid characters."
        exit 1
    fi

    # Session cookie flags. Omeka's session bootstrap (MvcListeners::
    # bootstrapSession) only forces name/httponly/strict-mode/only-cookies/
    # gc_maxlifetime and leaves cookie_secure and cookie_samesite to PHP's ini
    # values, so the pool is the right place to set them. php_value, NOT
    # php_admin_value: a deployment may still set these keys under
    # session.config in local.config.php, and Laminas' SessionConfig applies
    # those with ini_set() and throws when ini_set() fails — which is exactly
    # what a php_admin_value lock would cause, taking every page down.
    local cookie_secure="${OMEKA_SESSION_COOKIE_SECURE:-false}"
    local cookie_samesite="${OMEKA_SESSION_COOKIE_SAMESITE:-Lax}"
    local cookie_secure_value
    case "$cookie_secure" in
        true) cookie_secure_value=1 ;;
        false) cookie_secure_value=0 ;;
        *)
            log_error "OMEKA_SESSION_COOKIE_SECURE must be 'true' or 'false' (got '${cookie_secure}')."
            exit 1
            ;;
    esac
    case "$cookie_samesite" in
        Lax|Strict|None) ;;
        *)
            log_error "OMEKA_SESSION_COOKIE_SAMESITE must be 'Lax', 'Strict' or 'None' (got '${cookie_samesite}')."
            exit 1
            ;;
    esac
    # Browsers reject a SameSite=None cookie that is not also Secure, so this
    # combination would silently make every login fail.
    if [[ "$cookie_samesite" == "None" && "$cookie_secure" != "true" ]]; then
        log_error "OMEKA_SESSION_COOKIE_SAMESITE=None requires OMEKA_SESSION_COOKIE_SECURE=true (browsers drop the cookie otherwise)."
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
php_value[session.cookie_secure] = ${cookie_secure_value}
php_value[session.cookie_samesite] = ${cookie_samesite}
FPMEOF
    log_info "PHP-FPM pool: max_children=${PHP_PM_MAX_CHILDREN:-5}, start=${PHP_PM_START_SERVERS:-2}, min_spare=${PHP_PM_MIN_SPARE_SERVERS:-1}, max_spare=${PHP_PM_MAX_SPARE_SERVERS:-3}"
    log_info "Session cookie: Secure=${cookie_secure}, SameSite=${cookie_samesite}"
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

    if [[ "$already_installed" != true ]]; then
        log_step "Omeka S is not yet installed. Installing..."
        fresh_install=true
        if [[ -n "${OMEKA_ADMIN_EMAIL:-}" && -n "${OMEKA_ADMIN_PASSWORD:-}" && -n "${OMEKA_ADMIN_USERNAME:-}" ]]; then
            admin_created=true
            admin_email="${OMEKA_ADMIN_EMAIL}"
            admin_name="${OMEKA_ADMIN_USERNAME}"
            admin_password="${OMEKA_ADMIN_PASSWORD}"
            log_info "Creating admin user ${admin_email}"
        else
            # Omeka's installer always creates a first user. Left to itself,
            # omeka-s-cli falls back to admin@example.com with the password
            # "admin" — a published default on what may be a public site. So
            # when no (complete) admin account is configured, create that
            # placeholder account with a random password instead and show it
            # once in the first-install summary, the way the MySQL image does
            # for its generated root password.
            admin_email="${OMEKA_ADMIN_EMAIL:-admin@example.com}"
            admin_name="${OMEKA_ADMIN_USERNAME:-Admin}"
            admin_password="$(php -r 'echo bin2hex(random_bytes(12));')"
            generated_admin_password="$admin_password"
            log_info "No complete OMEKA_ADMIN_* account configured; generating an admin password."
        fi
        # omeka-s-cli echoes the options it was given, password included.
        # Mask it: a container log is read by more people, and kept longer,
        # than .env. pipefail keeps the installer's exit status.
        omeka-s-cli core:install \
                    --base-path "${OMEKA_ROOT}" \
                    --locale "${OMEKA_LOCALE}" \
                    --time-zone "${OMEKA_TZ:-UTC}" \
                    --title "${OMEKA_TITLE}" \
                    --admin-email "${admin_email}" \
                    --admin-name "${admin_name}" \
                    --admin-password "${admin_password}" 2>&1 \
            | while IFS= read -r line; do
                printf '%s\n' "${line//"$admin_password"/********}"
            done >&2
    else
        log_info "Omeka S is already installed. Good!"
        # The admin credentials are only read by the first install above. Left
        # in .env they keep a plaintext password in the container environment
        # (docker inspect, /proc/1/environ) for no benefit, and changing them
        # later does not change the real password either.
        if [[ -n "${OMEKA_ADMIN_PASSWORD:-}" ]]; then
            log_warn "OMEKA_ADMIN_PASSWORD is set, but it is only used by the first install."
            log_warn "Remove OMEKA_ADMIN_EMAIL, OMEKA_ADMIN_USERNAME and OMEKA_ADMIN_PASSWORD from .env"
            log_warn "and recreate the php container; change passwords in the Omeka admin instead."
        fi
    fi
}

# Prints the ids of downloaded modules whose state is "not_installed", one per
# line, from ONE omeka-s-cli boot. Fails (non-zero) if the listing cannot be
# read or does not look like omeka-s-cli's JSON, so the caller can fall back.
omeka_modules_not_installed() {
    local listing
    listing=$(omeka-s-cli module:list --base-path "$OMEKA_ROOT" --json --quiet) || return 1
    # shellcheck disable=SC2016 # PHP source: the $ belong to PHP, not bash
    printf '%s' "$listing" | php -r '
        $modules = json_decode(stream_get_contents(STDIN), true);
        if (!is_array($modules) || !array_is_list($modules)) {
            exit(1);
        }
        foreach ($modules as $module) {
            if (!is_array($module) || !is_string($module["id"] ?? null) || !is_string($module["state"] ?? null)
                || !preg_match("/^[A-Za-z0-9_.-]+$/", $module["id"])) {
                exit(1);
            }
            // omeka-s-cli passes through Omeka\Module\Manager::STATE_NOT_INSTALLED.
            if ($module["state"] === "not_installed") {
                echo $module["id"], "\n";
            }
        }
    '
}

omeka_modules_install() {
    # Every omeka-s-cli call boots Omeka (~1.5 s), so installing module by
    # module on each start added ~30 s to every php restart. Instead read all
    # module states once and only act on modules that are downloaded but not
    # installed (fresh images, or modules dropped into the volume). Installed
    # modules — active or deliberately deactivated — are left alone.
    #
    # An admin who UNINSTALLS a module puts it back into the same
    # "not_installed" state as a freshly downloaded one; Omeka keeps no record
    # of the difference. Such a module is installed again on the next start
    # unless its directory is deleted too, or OMEKA_AUTO_INSTALL_MODULES=false.
    local auto_install="${OMEKA_AUTO_INSTALL_MODULES:-true}"
    case "$auto_install" in
        true) ;;
        false)
            log_info "OMEKA_AUTO_INSTALL_MODULES=false: not installing modules automatically."
            return
            ;;
        *)
            log_error "OMEKA_AUTO_INSTALL_MODULES must be 'true' or 'false' (got '${auto_install}')."
            exit 1
            ;;
    esac

    log_step "Installing downloaded modules that are not installed yet..."
    local pending mod
    local -a modules=()
    if pending=$(omeka_modules_not_installed); then
        if [[ -z "$pending" ]]; then
            log_info "All downloaded modules are installed."
            return
        fi
        mapfile -t modules <<< "$pending"
        log_info "Not installed yet: ${modules[*]}"
        # --all installs exactly the not-installed modules in dependency
        # order within one boot, and carries on past a module that fails. It
        # exits 0 even then, so the result is checked by listing again.
        if omeka-s-cli module:install --base-path "$OMEKA_ROOT" --all \
            && pending=$(omeka_modules_not_installed); then
            if [[ -n "$pending" ]]; then
                while IFS= read -r mod; do
                    log_error "Failed to install module $mod"
                done <<< "$pending"
            fi
            return
        fi
        log_warn "Bulk module install did not complete; retrying module by module."
    else
        # Never skip installs just because the listing changed shape: fall
        # back to the old behaviour (module:install on an installed module is
        # a harmless "already installed" warning).
        log_warn "Could not read module states from omeka-s-cli; trying every module directory."
        for module_dir in "${OMEKA_ROOT}"/modules/*/; do
            [[ -d "$module_dir" ]] || continue
            modules+=("$(basename "$module_dir")")
        done
    fi

    for mod in "${modules[@]}"; do
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

# Short, copy-pasteable orientation for someone who has just brought the stack
# up for the first time and is reading `docker compose logs php`.
omeka_fresh_install_summary() {
    log_info "------------------------------------------------------------"
    log_info "Omeka S is installed and ready."
    if [[ "$admin_created" == true ]]; then
        log_info "Admin user created: ${admin_email} (password: the one from .env)."
    else
        log_info "Admin user created: ${admin_email}"
        log_info "Generated admin password: ${generated_admin_password}"
        log_info "It is shown only here. Sign in and change it under your user's"
        log_info "Password tab; set the e-mail address there too."
    fi
    log_info "Next steps:"
    log_info "  1. Open the site in a browser and sign in at /login."
    log_info "  2. Put HTTPS in front of it (a reverse proxy or load balancer)."
    log_info "  3. Once it is served over HTTPS, set OMEKA_SESSION_COOKIE_SECURE=true."
    if [[ -n "${OMEKA_ADMIN_PASSWORD:-}" ]]; then
        log_info "  4. Remove OMEKA_ADMIN_* from .env; they are not needed after this install."
    fi
    log_info "------------------------------------------------------------"
}

fresh_install=false
admin_created=false
admin_email=""
generated_admin_password=""

fpm_pool_config

# The DB config must be written first, as it is used during
# installation!
omeka_create_db_config
wait_for_db

# An installed database must never start against a media volume that isn't the
# one holding its files — an empty or wrongly-named volume would serve a site
# whose media has silently vanished. restore.sh writes this marker; fresh
# installs create it below, before initializing the database.
# Checked once here and reused by omeka_install: every omeka-s-cli call boots
# Omeka, so a second status probe only lengthens each start.
already_installed=false
if omeka-s-cli core:status --base-path "${OMEKA_ROOT}" --is-installed; then
    already_installed=true
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

if [[ "$fresh_install" == true ]]; then
    omeka_fresh_install_summary
fi

exec "$@"
