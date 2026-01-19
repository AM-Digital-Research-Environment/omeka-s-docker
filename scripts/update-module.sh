#!/bin/bash
# Script to update Omeka S modules from GitHub/GitLab
# Usage: ./update-module.sh <module-name> [branch/tag]
# Example: ./update-module.sh CSVImport
# Example: ./update-module.sh AdvancedSearch 3.5.46

set -e

# Configuration - Map module names to their GitHub repositories
declare -A MODULE_REPOS=(
    # Daniel-KM modules (GitHub)
    ["AdvancedSearch"]="Daniel-KM/Omeka-S-module-AdvancedSearch"
    ["AnalyticsSnippet"]="Daniel-KM/Omeka-S-module-AnalyticsSnippet"
    ["BulkEdit"]="Daniel-KM/Omeka-S-module-BulkEdit"
    ["BulkExport"]="Daniel-KM/Omeka-s-module-BulkExport"
    ["Common"]="Daniel-KM/Omeka-S-module-Common"
    ["EasyAdmin"]="Daniel-KM/Omeka-S-module-EasyAdmin"
    ["IiifServer"]="Daniel-KM/Omeka-S-module-IiifServer"
    ["ImageServer"]="Daniel-KM/Omeka-S-module-ImageServer"
    ["Log"]="Daniel-KM/Omeka-S-module-Log"
    ["OaiPmhRepository"]="Daniel-KM/Omeka-S-module-OaiPmhRepository"
    ["Reference"]="Daniel-KM/Omeka-S-module-Reference"
    ["SearchSolr"]="Daniel-KM/Omeka-S-module-SearchSolr"
    ["UniversalViewer"]="Daniel-KM/Omeka-S-module-UniversalViewer"

    # Official Omeka-S modules
    ["ActivityLog"]="omeka-s-modules/ActivityLog"
    ["Collecting"]="omeka-s-modules/Collecting"
    ["CSVImport"]="omeka-s-modules/CSVImport"
    ["CustomVocab"]="omeka-s-modules/CustomVocab"
    ["DataCleaning"]="omeka-s-modules/DataCleaning"
    ["FacetedBrowse"]="omeka-s-modules/FacetedBrowse"
    ["FileSideload"]="omeka-s-modules/FileSideload"
    ["Hierarchy"]="omeka-s-modules/Hierarchy"
    ["InverseProperties"]="omeka-s-modules/InverseProperties"
    ["ItemCarouselBlock"]="omeka-s-modules/ItemCarouselBlock"
    ["Mapping"]="omeka-s-modules/Mapping"
    ["NumericDataTypes"]="omeka-s-modules/NumericDataTypes"
    ["ResourceMeta"]="omeka-s-modules/ResourceMeta"

    # Other modules
    ["RightsStatements"]="zerocrates/RightsStatements"
    ["Sitemaps"]="ManOnDaMoon/omeka-s-module-Sitemaps"
)

# Configuration - Map module names to their GitLab repositories
declare -A GITLAB_REPOS=(
    # Daniel-KM modules (GitLab)
    ["IiifSearch"]="Daniel-KM/Omeka-S-module-IiifSearch"
    ["Internationalisation"]="Daniel-KM/Omeka-S-module-Internationalisation"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    echo "Usage: $0 <module-name> [branch/tag]"
    echo ""
    echo "Available modules (GitHub):"
    for module in "${!MODULE_REPOS[@]}"; do
        echo "  - $module"
    done | sort
    echo ""
    echo "Available modules (GitLab):"
    for module in "${!GITLAB_REPOS[@]}"; do
        echo "  - $module"
    done | sort
    echo ""
    echo "Options:"
    echo "  module-name    Name of the module to update"
    echo "  branch/tag     Optional: specific branch or tag (default: master)"
    echo ""
    echo "Examples:"
    echo "  $0 CSVImport"
    echo "  $0 AdvancedSearch 3.5.46"
    echo "  $0 all                    # Update all modules"
    exit 1
}

update_module() {
    local MODULE_NAME="$1"
    local BRANCH="${2:-master}"

    local REPO=""
    local BASE_URL=""
    local ARCHIVE_URL=""
    local IS_GITLAB=false

    if [[ -n "${MODULE_REPOS[$MODULE_NAME]}" ]]; then
        REPO="${MODULE_REPOS[$MODULE_NAME]}"
        BASE_URL="https://github.com/${REPO}"
        ARCHIVE_URL="${BASE_URL}/archive/refs/heads/${BRANCH}.zip"
    elif [[ -n "${GITLAB_REPOS[$MODULE_NAME]}" ]]; then
        REPO="${GITLAB_REPOS[$MODULE_NAME]}"
        BASE_URL="https://gitlab.com/${REPO}"
        ARCHIVE_URL="${BASE_URL}/-/archive/${BRANCH}/${REPO##*/}-${BRANCH}.zip"
        IS_GITLAB=true
    else
        log_error "Unknown module: $MODULE_NAME"
        echo "Use '$0' without arguments to see available modules"
        return 1
    fi

    local TEMP_DIR=$(mktemp -d)
    local CONTAINER_ID=$(docker compose ps -q php)

    if [[ -z "$CONTAINER_ID" ]]; then
        log_error "PHP container is not running. Start it with: docker compose up -d php"
        return 1
    fi

    log_info "Updating module: $MODULE_NAME from $BASE_URL (branch: $BRANCH)"

    log_info "Downloading module..."
    if ! curl -sL "$ARCHIVE_URL" -o "$TEMP_DIR/module.zip"; then
        if [[ "$IS_GITLAB" == true ]]; then
            ARCHIVE_URL="${BASE_URL}/-/archive/${BRANCH}/${REPO##*/}-${BRANCH}.zip"
        else
            ARCHIVE_URL="${BASE_URL}/archive/refs/tags/${BRANCH}.zip"
        fi
        log_warn "Branch not found, trying as tag..."
        if ! curl -sL "$ARCHIVE_URL" -o "$TEMP_DIR/module.zip"; then
            log_error "Failed to download module. Check if branch/tag '$BRANCH' exists."
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
    docker cp "$TEMP_DIR/$MODULE_NAME" "$CONTAINER_ID:/var/www/html/modules/"

    log_info "Setting ownership and permissions..."
    docker compose exec -T php chown -R www-data:www-data "/var/www/html/modules/$MODULE_NAME"
    docker compose exec -T php chmod -R 775 "/var/www/html/modules/$MODULE_NAME"

    rm -rf "$TEMP_DIR"

    log_info "Module $MODULE_NAME updated successfully!"

    if docker compose exec -T php test -f "/var/www/html/modules/$MODULE_NAME/composer.json"; then
        log_info "Installing composer dependencies..."
        if docker compose exec -T php bash -c "cd /var/www/html/modules/$MODULE_NAME && composer install --no-dev --quiet"; then
            log_info "Composer dependencies installed successfully!"
        else
            log_warn "Failed to install composer dependencies. You may need to run manually:"
            echo "  docker compose exec php bash -c 'cd /var/www/html/modules/$MODULE_NAME && composer install --no-dev'"
        fi
    fi
}

update_all_modules() {
    local BRANCH="${1:-master}"
    log_info "Updating all modules..."

    for module in "${!MODULE_REPOS[@]}"; do
        echo ""
        echo "=========================================="
        update_module "$module" "$BRANCH"
    done

    for module in "${!GITLAB_REPOS[@]}"; do
        echo ""
        echo "=========================================="
        update_module "$module" "$BRANCH"
    done

    echo ""
    log_info "All modules updated!"
}

# Main script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [[ $# -lt 1 ]]; then
    usage
fi

MODULE_NAME="$1"
BRANCH="${2:-master}"

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

if [[ "$MODULE_NAME" == "all" ]]; then
    update_all_modules "$BRANCH"
else
    update_module "$MODULE_NAME" "$BRANCH"
fi

echo ""
log_info "Don't forget to:"
echo "  1. Clear Omeka S cache if needed"
echo "  2. Check the module in Omeka S admin panel"
