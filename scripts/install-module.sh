#!/bin/bash
# Script to install Omeka S modules from GitHub/GitLab
# Usage: ./install-module.sh <module-name> [branch/tag]
# Example: ./install-module.sh AdvancedSearch
# Example: ./install-module.sh AdvancedSearch 3.5.46

set -e

# Pre-installed modules (installed automatically with Omeka S)
PREINSTALLED_MODULES=(
    "ActivityLog"
    "Collecting"
    "CSVImport"
    "CustomVocab"
    "DataCleaning"
    "Datavis"
    "FacetedBrowse"
    "FileSideload"
    "IframeEmbed"
    "Mapping"
    "NumericDataTypes"
    "ZoteroImport"
)

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
    ["IframeEmbed"]="fmadore/IframeEmbed:main"
    ["RightsStatements"]="zerocrates/RightsStatements:master"
    ["Sitemaps"]="ManOnDaMoon/omeka-s-module-Sitemaps:master"
)

# Configuration - Map module names to their GitLab repositories
# Format: "repo:branch"
declare -A GITLAB_REPOS=(
    # Daniel-KM modules (GitLab)
    ["IiifSearch"]="Daniel-KM/Omeka-S-module-IiifSearch:master"
    ["Internationalisation"]="Daniel-KM/Omeka-S-module-Internationalisation:master"
)

# Module dependencies - modules that must be installed first
# Format: "dependency1 dependency2 ..."
declare -A MODULE_DEPENDENCIES=(
    ["EasyAdmin"]="Common Cron"
    ["AdvancedSearch"]="Common"
    ["BulkEdit"]="Common"
    ["BulkExport"]="Common"
    ["IiifServer"]="Common"
    ["ImageServer"]="Common"
    ["Log"]="Common"
    ["OaiPmhRepository"]="Common"
    ["Reference"]="Common"
    ["SearchSolr"]="Common AdvancedSearch"
    ["UniversalViewer"]="Common"
    ["IiifSearch"]="Common"
    ["Internationalisation"]="Common"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to check if a module is pre-installed
is_preinstalled() {
    local module="$1"
    for preinstalled in "${PREINSTALLED_MODULES[@]}"; do
        if [[ "$preinstalled" == "$module" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to check if a module is already installed in the container
is_module_installed() {
    local module="$1"
    docker compose exec -T php test -d "/var/www/html/modules/$module" 2>/dev/null
}

# Function to install module dependencies
install_dependencies() {
    local MODULE_NAME="$1"
    local deps="${MODULE_DEPENDENCIES[$MODULE_NAME]}"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    log_info "Checking dependencies for $MODULE_NAME: $deps"

    for dep in $deps; do
        if ! is_module_installed "$dep"; then
            log_info "Installing required dependency: $dep"
            # Recursively install dependencies (in case the dependency has its own dependencies)
            install_dependencies "$dep"
            install_module "$dep"
            if [[ $? -ne 0 ]]; then
                log_error "Failed to install dependency: $dep"
                return 1
            fi
        else
            log_info "Dependency $dep is already installed"
        fi
    done

    return 0
}

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

# Function to display usage
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
    echo "  module-name    Name of the module to install"
    echo "  branch/tag     Optional: override default branch/tag"
    echo ""
    echo "Examples:"
    echo "  $0 CSVImport              # Uses default branch (develop)"
    echo "  $0 AdvancedSearch 3.5.46  # Override with specific tag"
    echo "  $0 list                   # List all available modules"
    exit 1
}

# Function to install a single module
install_module() {
    local MODULE_NAME="$1"
    local BRANCH_OVERRIDE="$2"

    # Get module info (repo, default branch, is_gitlab)
    local module_info
    module_info=$(get_module_info "$MODULE_NAME")
    if [[ $? -ne 0 ]]; then
        log_error "Unknown module: $MODULE_NAME"
        echo ""
        echo "Use '$0 list' to see available modules"
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

    # Check if module is pre-installed
    if is_preinstalled "$MODULE_NAME"; then
        log_info "Module $MODULE_NAME is pre-installed by default."
        if docker compose exec -T php test -d "/var/www/html/modules/$MODULE_NAME"; then
            log_info "Module is already present. Use update-module.sh to update it if needed."
            return 0
        fi
    fi

    # Check if module already exists
    if docker compose exec -T php test -d "/var/www/html/modules/$MODULE_NAME"; then
        log_warn "Module $MODULE_NAME already exists. Use update-module.sh to update it."
        return 0
    fi

    log_info "Installing module: $MODULE_NAME from $BASE_URL (branch: $BRANCH)"

    # Download the module
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

    # Extract the module
    log_info "Extracting module..."
    unzip -q "$TEMP_DIR/module.zip" -d "$TEMP_DIR"

    # Find the extracted directory
    EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "Omeka-S-module-*" -o -type d -name "Omeka-s-module-*" | head -1)
    if [[ -z "$EXTRACTED_DIR" ]]; then
        EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -name "$(basename "$TEMP_DIR")" | head -1)
    fi
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_error "Failed to find extracted module directory"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    # Rename to proper module name
    mv "$EXTRACTED_DIR" "$TEMP_DIR/$MODULE_NAME"

    # Copy module to container
    log_info "Copying module to container..."
    docker cp "$TEMP_DIR/$MODULE_NAME" "$CONTAINER_ID:/var/www/html/modules/"

    # Set proper ownership and permissions
    log_info "Setting ownership and permissions..."
    docker compose exec -T php chown -R www-data:www-data "/var/www/html/modules/$MODULE_NAME"
    docker compose exec -T php chmod -R 775 "/var/www/html/modules/$MODULE_NAME"

    # Cleanup
    rm -rf "$TEMP_DIR"

    log_info "Module $MODULE_NAME installed successfully!"

    # Install composer dependencies if composer.json exists
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

# Main script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Check arguments
if [[ $# -lt 1 ]]; then
    usage
fi

MODULE_NAME="$1"
BRANCH_OVERRIDE="$2"  # Optional: override default branch

# Check if docker compose is available
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

# List modules if requested
if [[ "$MODULE_NAME" == "list" ]]; then
    echo "Pre-installed modules (included by default):"
    for module in "${PREINSTALLED_MODULES[@]}"; do
        echo "  - $module"
    done | sort
    echo ""
    echo "Available modules (GitHub):"
    for module in "${!MODULE_REPOS[@]}"; do
        local entry="${MODULE_REPOS[$module]}"
        local branch="${entry##*:}"
        if is_preinstalled "$module"; then
            echo "  - $module [branch: $branch] (pre-installed)"
        else
            echo "  - $module [branch: $branch]"
        fi
    done | sort
    echo ""
    echo "Available modules (GitLab):"
    for module in "${!GITLAB_REPOS[@]}"; do
        local entry="${GITLAB_REPOS[$module]}"
        local branch="${entry##*:}"
        echo "  - $module [branch: $branch]"
    done | sort
    exit 0
fi

# Install dependencies first (if any)
install_dependencies "$MODULE_NAME"
if [[ $? -ne 0 ]]; then
    log_error "Failed to install dependencies for $MODULE_NAME"
    exit 1
fi

# Install the requested module
install_module "$MODULE_NAME" "$BRANCH_OVERRIDE"

echo ""
log_info "Don't forget to:"
echo "  1. Activate the module (and any dependencies) in Omeka S admin panel"
echo "  2. Configure the module as needed"
echo ""
if [[ -n "${MODULE_DEPENDENCIES[$MODULE_NAME]}" ]]; then
    log_info "Note: Dependencies were auto-installed: ${MODULE_DEPENDENCIES[$MODULE_NAME]}"
    echo "  Make sure to activate them in the correct order in Omeka S admin."
fi
