#!/bin/bash
# Script to update Omeka S modules from GitHub/GitLab
# Usage: bash scripts/update-module.sh <module-name> [branch/tag]
# Example: bash scripts/update-module.sh DRESearch
# Example: bash scripts/update-module.sh AdvancedSearch 3.5.46

set -e

# Configuration - Map module names to their repositories and default branches
# Format: "repo:branch"
declare -A MODULE_REPOS=(
    # Daniel-KM modules (GitHub)
    ["AdvancedSearch"]="Daniel-KM/Omeka-S-module-AdvancedSearch:master"
    ["AnalyticsSnippet"]="Daniel-KM/Omeka-S-module-AnalyticsSnippet:master"
    ["BulkEdit"]="Daniel-KM/Omeka-S-module-BulkEdit:master"
    ["BulkExport"]="Daniel-KM/Omeka-S-module-BulkExport:master"
    ["Common"]="Daniel-KM/Omeka-S-module-Common:master"
    ["Cron"]="Daniel-KM/Omeka-S-module-Cron:master"
    ["EasyAdmin"]="Daniel-KM/Omeka-S-module-EasyAdmin:master"
    ["IiifServer"]="Daniel-KM/Omeka-S-module-IiifServer:master"
    ["ImageServer"]="Daniel-KM/Omeka-S-module-ImageServer:master"
    ["Log"]="Daniel-KM/Omeka-S-module-Log:master"
    ["OaiPmhRepository"]="Daniel-KM/Omeka-S-module-OaiPmhRepository:master"
    ["Reference"]="Daniel-KM/Omeka-S-module-Reference:master"
    ["SearchSolr"]="Daniel-KM/Omeka-S-module-SearchSolr:master"
    ["UniversalViewer"]="Daniel-KM/Omeka-S-module-UniversalViewer:master"

    # Official Omeka-S modules
    ["ActivityLog"]="omeka-s-modules/ActivityLog:master"
    ["Collecting"]="omeka-s-modules/Collecting:master"
    ["CSSEditor"]="omeka-s-modules/CSSEditor:master"
    ["CSVImport"]="omeka-s-modules/CSVImport:develop"
    ["CustomVocab"]="omeka-s-modules/CustomVocab:master"
    ["DataCleaning"]="omeka-s-modules/DataCleaning:master"
    ["Datavis"]="omeka-s-modules/Datavis:main"
    ["DspaceConnector"]="omeka-s-modules/DspaceConnector:develop"
    ["Exports"]="omeka-s-modules/Exports:main"
    ["FacetedBrowse"]="omeka-s-modules/FacetedBrowse:master"
    ["FileSideload"]="omeka-s-modules/FileSideload:master"
    ["Hierarchy"]="omeka-s-modules/Hierarchy:main"
    ["InverseProperties"]="omeka-s-modules/InverseProperties:main"
    ["ItemCarouselBlock"]="omeka-s-modules/ItemCarouselBlock:master"
    ["Mapping"]="omeka-s-modules/Mapping:master"
    ["NumericDataTypes"]="omeka-s-modules/NumericDataTypes:master"
    ["OutputFormats"]="omeka-s-modules/OutputFormats:main"
    ["ResourceMeta"]="omeka-s-modules/ResourceMeta:master"
    ["ValueSuggest"]="omeka-s-modules/ValueSuggest:master"
    ["ZoteroImport"]="omeka-s-modules/ZoteroImport:master"

    # Other modules
    ["DRESearch"]="AM-Digital-Research-Environment/DRESearch:main"
    # Repo is DRE-SEO but the module namespace/dir is DRESeo, so that must be the key.
    ["DRESeo"]="AM-Digital-Research-Environment/DRE-SEO:main"
    ["ResourceVisualizations"]="fmadore/ResourceVisualizations:main"
    ["RightsStatements"]="zerocrates/RightsStatements:master"
    ["Sitemaps"]="ManOnDaMoon/omeka-s-module-Sitemaps:master"
    ["Wikidata"]="nishad/omeka-s-wikidata:master"
)

# Configuration - Map module names to their GitLab repositories
# Format: "repo:branch"
declare -A GITLAB_REPOS=(
    # Daniel-KM modules (GitLab)
    ["IiifSearch"]="Daniel-KM/Omeka-S-module-IiifSearch:master"
    ["Internationalisation"]="Daniel-KM/Omeka-S-module-Internationalisation:master"
)

# Function to get repo and branch from MODULE_REPOS or GITLAB_REPOS
get_module_info() {
    local MODULE_NAME="$1"
    local entry=""
    local is_gitlab=false

    if [[ -n "${MODULE_REPOS[$MODULE_NAME]}" ]]; then
        entry="${MODULE_REPOS[$MODULE_NAME]}"
    elif [[ -n "${GITLAB_REPOS[$MODULE_NAME]}" ]]; then
        entry="${GITLAB_REPOS[$MODULE_NAME]}"
        is_gitlab=true
    else
        return 1
    fi

    # Parse "repo:branch" format
    local repo="${entry%%:*}"
    local branch="${entry##*:}"

    echo "$repo|$branch|$is_gitlab"
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Reset PHP-FPM's OPcache after swapping module files. The php image runs
# opcache.validate_timestamps=0, so FPM keeps serving the OLD compiled bytecode
# of the module's PHP (including config/module.config.php) until the cache is
# cleared. Skipping this surfaces as "Unable to resolve service ..."
# ServiceNotFoundException errors on pages an updated module added.
#
# Reset via cgi-fcgi rather than `docker compose restart php` so the container
# keeps its IP (nginx caches the php upstream and would otherwise 502 until web
# is also restarted) and active sessions are preserved.
reset_opcache() {
    if [[ -z "$(docker compose ps -q php)" ]]; then
        log_warn "PHP container not running; skipping OPcache reset."
        return 0
    fi
    log_info "Resetting PHP-FPM OPcache so the updated code goes live..."
    if docker compose exec -T php sh -c 'printf "<?php opcache_reset();" > /tmp/opcache-reset.php; \
        SCRIPT_NAME=/opcache-reset.php SCRIPT_FILENAME=/tmp/opcache-reset.php REQUEST_METHOD=GET \
        cgi-fcgi -bind -connect 127.0.0.1:9000 >/dev/null 2>&1; status=$?; \
        rm -f /tmp/opcache-reset.php; exit $status'; then
        log_info "OPcache reset."
    else
        log_warn "OPcache reset failed. Run manually:"
        echo "  docker compose exec php sh -c 'printf \"<?php opcache_reset();\" > /tmp/r.php; SCRIPT_NAME=/r.php SCRIPT_FILENAME=/tmp/r.php REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000'"
    fi
}

usage() {
    echo "Usage: $0 <module-name> [branch/tag]"
    echo ""
    echo "Available modules (GitHub):"
    for module in "${!MODULE_REPOS[@]}"; do
        local entry="${MODULE_REPOS[$module]}"
        local branch="${entry##*:}"
        echo "  - $module (default: $branch)"
    done | sort
    echo ""
    echo "Available modules (GitLab):"
    for module in "${!GITLAB_REPOS[@]}"; do
        local entry="${GITLAB_REPOS[$module]}"
        local branch="${entry##*:}"
        echo "  - $module (default: $branch)"
    done | sort
    echo ""
    echo "Options:"
    echo "  module-name    Name of the module to update"
    echo "  branch/tag     Optional: override default branch/tag"
    echo ""
    echo "Examples:"
    echo "  $0 CSVImport              # Uses default branch (develop)"
    echo "  $0 AdvancedSearch 3.5.46  # Override with specific tag"
    echo "  $0 all                    # Update all installed modules"
    exit 1
}

update_module() {
    local MODULE_NAME="$1"
    local BRANCH_OVERRIDE="$2"

    # Get module info (repo, default branch, is_gitlab)
    local module_info
    module_info=$(get_module_info "$MODULE_NAME")
    if [[ $? -ne 0 ]]; then
        log_error "Unknown module: $MODULE_NAME"
        echo "Use '$0' without arguments to see available modules"
        return 1
    fi

    # Parse module info
    local REPO="${module_info%%|*}"
    local remainder="${module_info#*|}"
    local DEFAULT_BRANCH="${remainder%%|*}"
    local IS_GITLAB="${remainder##*|}"

    # Use override branch if provided, otherwise use default
    local BRANCH="${BRANCH_OVERRIDE:-$DEFAULT_BRANCH}"

    local BASE_URL=""
    local ARCHIVE_URL=""

    if [[ "$IS_GITLAB" == "true" ]]; then
        BASE_URL="https://gitlab.com/${REPO}"
        ARCHIVE_URL="${BASE_URL}/-/archive/${BRANCH}/${REPO##*/}-${BRANCH}.zip"
    else
        BASE_URL="https://github.com/${REPO}"
        ARCHIVE_URL="${BASE_URL}/archive/refs/heads/${BRANCH}.zip"
    fi

    local TEMP_DIR=$(mktemp -d)
    local CONTAINER_ID=$(docker compose ps -q php)

    if [[ -z "$CONTAINER_ID" ]]; then
        log_error "PHP container is not running. Start it with: docker compose up -d php"
        return 1
    fi

    log_info "Updating module: $MODULE_NAME from $BASE_URL (branch: $BRANCH)"

    log_info "Downloading module..."
    local HTTP_CODE
    HTTP_CODE=$(curl -sL -w "%{http_code}" "$ARCHIVE_URL" -o "$TEMP_DIR/module.zip")
    if [[ "$HTTP_CODE" != "200" ]]; then
        # Try as a tag if branch fails
        if [[ "$IS_GITLAB" == "true" ]]; then
            ARCHIVE_URL="${BASE_URL}/-/archive/${BRANCH}/${REPO##*/}-${BRANCH}.zip"
        else
            ARCHIVE_URL="${BASE_URL}/archive/refs/tags/${BRANCH}.zip"
        fi
        log_warn "Branch not found (HTTP $HTTP_CODE), trying as tag..."
        HTTP_CODE=$(curl -sL -w "%{http_code}" "$ARCHIVE_URL" -o "$TEMP_DIR/module.zip")
        if [[ "$HTTP_CODE" != "200" ]]; then
            log_error "Failed to download module (HTTP $HTTP_CODE). Check if branch/tag '$BRANCH' exists."
            rm -rf "$TEMP_DIR"
            return 1
        fi
    fi

    log_info "Extracting module..."
    unzip -q "$TEMP_DIR/module.zip" -d "$TEMP_DIR"

    EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "Omeka-S-module-*" -o -type d -name "Omeka-s-module-*" | head -1)
    if [[ -z "$EXTRACTED_DIR" ]]; then
        EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -name "$(basename "$TEMP_DIR")" | head -1)
    fi
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_error "Failed to find extracted module directory"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    mv "$EXTRACTED_DIR" "$TEMP_DIR/$MODULE_NAME"

    log_info "Removing existing module from container..."
    docker compose exec -T php rm -rf "/var/www/html/modules/$MODULE_NAME"

    log_info "Copying new module to container..."
    # Pipe a tar stream so files are extracted by the in-container user
    # (www-data) and land already owned by www-data. `docker cp` would import
    # files with the host UID, which www-data cannot chown afterwards because
    # the container drops CAP_CHOWN (see docker-compose.yml: cap_drop: ALL).
    tar -C "$TEMP_DIR" -cf - "$MODULE_NAME" \
        | docker compose exec -T php tar -xf - -C /var/www/html/modules/

    log_info "Setting permissions..."
    docker compose exec -T php chmod -R 775 "/var/www/html/modules/$MODULE_NAME"

    rm -rf "$TEMP_DIR"

    log_info "Module $MODULE_NAME updated successfully!"

    if docker compose exec -T php test -f "/var/www/html/modules/$MODULE_NAME/composer.json"; then
        log_info "Installing composer dependencies..."
        docker compose exec -T php bash -c "source /usr/local/bin/ensure-composer.sh && ensure_composer"
        # Pin composer's metadata cache to the www-data-writable /var/www/.cache.
        # Its default ($HOME/.composer = /var/www/.composer) is root-owned, so
        # composer otherwise runs cacheless and re-downloads every package's
        # metadata on each run; in this environment those live fetches
        # intermittently truncate and composer misreports them as bogus version
        # conflicts (e.g. "only one of these can be installed:
        # php-http/guzzle7-adapter"). A warm cache makes resolution consistent;
        # we still retry once to absorb a flaky first fetch. (The Dockerfile
        # bakes COMPOSER_CACHE_DIR in too; this inline copy keeps already-built
        # containers working without a rebuild.)
        local composer_run="cd /var/www/html/modules/$MODULE_NAME && COMPOSER_CACHE_DIR=/var/www/.cache/composer composer install --no-dev"
        local composer_ok=false
        for attempt in 1 2; do
            if docker compose exec -T php bash -c "$composer_run"; then
                composer_ok=true
                break
            fi
            if [[ $attempt -lt 2 ]]; then
                log_warn "Composer install failed (attempt $attempt); retrying with a warm cache..."
            fi
        done
        if [[ "$composer_ok" == true ]]; then
            log_info "Composer dependencies installed successfully!"
        else
            log_error "Composer dependencies FAILED for $MODULE_NAME after 2 attempts."
            log_error "The module will NOT load until they install (its Module.php may 'require vendor/autoload.php'). Run manually:"
            echo "  docker compose exec php bash -c 'cd /var/www/html/modules/$MODULE_NAME && COMPOSER_CACHE_DIR=/var/www/.cache/composer composer install --no-dev'"
        fi
    fi
}

update_all_modules() {
    log_info "Updating all installed modules..."

    local CONTAINER_ID=$(docker compose ps -q php)
    if [[ -z "$CONTAINER_ID" ]]; then
        log_error "PHP container is not running. Start it with: docker compose up -d php"
        return 1
    fi

    # Only update modules that are actually installed
    for module in "${!MODULE_REPOS[@]}"; do
        if docker compose exec -T php test -d "/var/www/html/modules/$module"; then
            echo ""
            echo "=========================================="
            update_module "$module"
        fi
    done

    for module in "${!GITLAB_REPOS[@]}"; do
        if docker compose exec -T php test -d "/var/www/html/modules/$module"; then
            echo ""
            echo "=========================================="
            update_module "$module"
        fi
    done

    echo ""
    log_info "All installed modules updated!"
}

# Main script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [[ $# -lt 1 ]]; then
    usage
fi

MODULE_NAME="$1"
BRANCH_OVERRIDE="$2"  # Optional: override default branch

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

if [[ "$MODULE_NAME" == "all" ]]; then
    update_all_modules
else
    update_module "$MODULE_NAME" "$BRANCH_OVERRIDE"
fi

# Clear FPM's OPcache so the new module code (config + classes) is actually
# served — otherwise opcache.validate_timestamps=0 keeps the old bytecode live.
reset_opcache

echo ""
log_info "Don't forget to:"
echo "  1. Check the module in Omeka S admin panel"
