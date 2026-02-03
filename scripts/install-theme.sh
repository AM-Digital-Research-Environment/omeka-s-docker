#!/bin/bash
# Script to install Omeka S themes from GitHub
# Usage: bash scripts/install-theme.sh <theme-name> [branch/tag]
# Example: bash scripts/install-theme.sh CenterRow
# Example: bash scripts/install-theme.sh Foundation 1.4.0

set -e

# Configuration - Map theme names to their GitHub repositories
declare -A THEME_REPOS=(
    # Official Omeka S themes
    ["CenterRow"]="omeka-s-themes/CenterRow"
    ["Cozy"]="omeka-s-themes/Cozy"
    ["Freedom"]="omeka-s-themes/Freedom"
    ["Lively"]="omeka-s-themes/Lively"
    ["Papers"]="omeka-s-themes/Papers"
    ["Foundation"]="omeka-s-themes/Foundation"
    ["ThankRoy"]="omeka-s-themes/ThankRoy"
    ["Thedarkside"]="omeka-s-themes/Thedarkside"
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
    echo "Usage: $0 <theme-name> [branch/tag]"
    echo ""
    echo "Available themes:"
    for theme in "${!THEME_REPOS[@]}"; do
        echo "  - $theme"
    done | sort
    echo ""
    echo "Options:"
    echo "  theme-name     Name of the theme to install"
    echo "  branch/tag     Optional: specific branch or tag (default: master)"
    echo ""
    echo "Examples:"
    echo "  $0 CenterRow"
    echo "  $0 Foundation 1.4.0"
    echo "  $0 list                  # List all available themes"
    exit 1
}

install_theme() {
    local THEME_NAME="$1"
    local BRANCH="${2:-master}"

    if [[ -z "${THEME_REPOS[$THEME_NAME]}" ]]; then
        log_error "Unknown theme: $THEME_NAME"
        echo ""
        echo "Use '$0 list' to see available themes"
        return 1
    fi

    local REPO="${THEME_REPOS[$THEME_NAME]}"
    local BASE_URL="https://github.com/${REPO}"
    local ARCHIVE_URL="${BASE_URL}/archive/refs/heads/${BRANCH}.zip"
    local TEMP_DIR=$(mktemp -d)
    local CONTAINER_ID=$(docker compose ps -q php)

    if [[ -z "$CONTAINER_ID" ]]; then
        log_error "PHP container is not running. Start it with: docker compose up -d php"
        return 1
    fi

    # Check if theme already exists
    if docker compose exec -T php test -d "/var/www/html/themes/$THEME_NAME"; then
        log_warn "Theme $THEME_NAME already exists. Removing and reinstalling..."
        docker compose exec -T php rm -rf "/var/www/html/themes/$THEME_NAME"
    fi

    log_info "Installing theme: $THEME_NAME from $BASE_URL (branch: $BRANCH)"

    log_info "Downloading theme..."
    if ! curl -sL "$ARCHIVE_URL" -o "$TEMP_DIR/theme.zip"; then
        # Try as a tag
        ARCHIVE_URL="${BASE_URL}/archive/refs/tags/${BRANCH}.zip"
        log_warn "Branch not found, trying as tag..."
        if ! curl -sL "$ARCHIVE_URL" -o "$TEMP_DIR/theme.zip"; then
            log_error "Failed to download theme. Check if branch/tag '$BRANCH' exists."
            rm -rf "$TEMP_DIR"
            return 1
        fi
    fi

    log_info "Extracting theme..."
    unzip -q "$TEMP_DIR/theme.zip" -d "$TEMP_DIR"

    # Find the extracted directory
    EXTRACTED_DIR=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -name "$(basename "$TEMP_DIR")" | head -1)
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_error "Failed to find extracted theme directory"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    # Rename to proper theme name
    mv "$EXTRACTED_DIR" "$TEMP_DIR/$THEME_NAME"

    # Copy theme to container
    log_info "Copying theme to container..."
    docker cp "$TEMP_DIR/$THEME_NAME" "$CONTAINER_ID:/var/www/html/themes/"

    # Set proper ownership and permissions
    log_info "Setting ownership and permissions..."
    docker compose exec -T php chown -R www-data:www-data "/var/www/html/themes/$THEME_NAME"
    docker compose exec -T php chmod -R 775 "/var/www/html/themes/$THEME_NAME"

    rm -rf "$TEMP_DIR"

    log_info "Theme $THEME_NAME installed successfully!"
}

# Main script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [[ $# -lt 1 ]]; then
    usage
fi

THEME_NAME="$1"
BRANCH="${2:-master}"

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

# List themes if requested
if [[ "$THEME_NAME" == "list" ]]; then
    echo "Available themes:"
    for theme in "${!THEME_REPOS[@]}"; do
        echo "  - $theme"
    done | sort
    exit 0
fi

install_theme "$THEME_NAME" "$BRANCH"

echo ""
log_info "Don't forget to:"
echo "  1. Activate the theme in Omeka S admin panel (Appearance > Themes)"
echo "  2. Configure the theme settings as needed"
