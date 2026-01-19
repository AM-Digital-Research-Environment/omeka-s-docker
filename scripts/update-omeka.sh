#!/bin/bash
# Script to update Omeka S core from GitHub releases
# Usage: ./update-omeka.sh [version] [--dry-run]
# Example: ./update-omeka.sh 4.2.0
# Example: ./update-omeka.sh latest
# Example: ./update-omeka.sh 4.2.0 --dry-run

set -e

# Configuration
OMEKA_REPO="omeka/omeka-s"
BACKUP_DIR="/var/www/html/omeka-backups"
OMEKA_ROOT="/var/www/html"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

usage() {
    echo "Usage: $0 [version] [--dry-run]"
    echo ""
    echo "Update Omeka S core to a specific version or latest release."
    echo ""
    echo "Arguments:"
    echo "  version      Target version (e.g., 4.2.0) or 'latest' (default: latest)"
    echo "  --dry-run    Show what would be done without making changes"
    echo ""
    echo "Examples:"
    echo "  $0                    # Update to latest version"
    echo "  $0 4.2.0              # Update to version 4.2.0"
    echo "  $0 latest --dry-run   # Preview update to latest version"
    echo ""
    echo "Important Notes:"
    echo "  - The /files directory is preserved in-place (not copied)"
    echo "  - Backups of /config, /modules, /themes are created"
    echo "  - After update, visit your site to run any database migrations"
    exit 1
}

get_latest_version() {
    local latest
    latest=$(curl -sL "https://api.github.com/repos/${OMEKA_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$latest" ]]; then
        log_error "Failed to fetch latest version from GitHub"
        exit 1
    fi
    echo "$latest"
}

get_current_version() {
    local version
    if docker compose exec -T php test -f "${OMEKA_ROOT}/application/Module.php"; then
        version=$(docker compose exec -T php grep "const VERSION" "${OMEKA_ROOT}/application/Module.php" 2>/dev/null | sed -E "s/.*'([^']+)'.*/\1/" || echo "unknown")
    else
        version="unknown"
    fi
    echo "$version"
}

# Parse arguments
DRY_RUN=false
VERSION="latest"

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        --help|-h)
            usage
            ;;
        *)
            VERSION="$arg"
            ;;
    esac
done

# Main script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

CONTAINER_ID=$(docker compose ps -q php)
if [[ -z "$CONTAINER_ID" ]]; then
    log_error "PHP container is not running. Start it with: docker compose up -d php"
    exit 1
fi

if [[ "$VERSION" == "latest" ]]; then
    log_info "Fetching latest version from GitHub..."
    VERSION=$(get_latest_version)
fi

VERSION="${VERSION#v}"

CURRENT_VERSION=$(get_current_version)
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/backup_${BACKUP_TIMESTAMP}"

echo ""
echo "========================================"
echo "       Omeka S Core Update Script       "
echo "========================================"
echo ""
log_info "Current version: ${CURRENT_VERSION}"
log_info "Target version:  ${VERSION}"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
    echo ""
fi

ARCHIVE_URL="https://github.com/${OMEKA_REPO}/releases/download/v${VERSION}/omeka-s-${VERSION}.zip"

log_step "Verifying release v${VERSION} exists..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would check: $ARCHIVE_URL"
else
    HTTP_CODE=$(curl -sL -o /dev/null -w "%{http_code}" "$ARCHIVE_URL")
    if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "302" ]]; then
        log_error "Release v${VERSION} not found at GitHub. HTTP code: $HTTP_CODE"
        log_info "Check available releases at: https://github.com/${OMEKA_REPO}/releases"
        exit 1
    fi
    log_info "Release verified!"
fi

log_step "Step 1: Creating backup directory..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would create: ${BACKUP_PATH}"
else
    docker compose exec -T php mkdir -p "${BACKUP_PATH}"
    log_info "Backup directory: ${BACKUP_PATH}"
fi

log_step "Step 2: Backing up /config directory..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would backup: ${OMEKA_ROOT}/config -> ${BACKUP_PATH}/config"
else
    docker compose exec -T php cp -r "${OMEKA_ROOT}/config" "${BACKUP_PATH}/config"
    log_info "Config backed up successfully"
fi

log_step "Step 3: Backing up /modules directory..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would backup: ${OMEKA_ROOT}/modules -> ${BACKUP_PATH}/modules"
else
    docker compose exec -T php cp -r "${OMEKA_ROOT}/modules" "${BACKUP_PATH}/modules"
    log_info "Modules backed up successfully"
fi

log_step "Step 4: Backing up /themes directory..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would backup: ${OMEKA_ROOT}/themes -> ${BACKUP_PATH}/themes"
else
    docker compose exec -T php cp -r "${OMEKA_ROOT}/themes" "${BACKUP_PATH}/themes"
    log_info "Themes backed up successfully"
fi

log_info "Note: /files directory will be preserved in-place (not copied)"

log_step "Step 5: Downloading Omeka S v${VERSION}..."
TEMP_DIR=$(mktemp -d)
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would download: ${ARCHIVE_URL}"
else
    if ! curl -sL "$ARCHIVE_URL" -o "${TEMP_DIR}/omeka-s.zip"; then
        log_error "Failed to download Omeka S v${VERSION}"
        rm -rf "${TEMP_DIR}"
        exit 1
    fi
    log_info "Download complete"
fi

log_step "Step 6: Extracting new release..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would extract to: ${TEMP_DIR}/omeka-s"
else
    unzip -q "${TEMP_DIR}/omeka-s.zip" -d "${TEMP_DIR}"
    EXTRACTED_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d -name "omeka-s*" | head -1)
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_error "Failed to find extracted Omeka S directory"
        rm -rf "${TEMP_DIR}"
        exit 1
    fi
    log_info "Extracted to: ${EXTRACTED_DIR}"
fi

log_step "Step 7: Removing old Omeka S core files..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would remove core files while preserving user data"
else
    docker compose exec -T php bash -c "
        cd ${OMEKA_ROOT} && \
        find . -maxdepth 1 \
            ! -name '.' \
            ! -name 'files' \
            ! -name 'modules' \
            ! -name 'themes' \
            ! -name 'config' \
            ! -name 'omeka-backups' \
            ! -name 'sideload' \
            -exec rm -rf {} + 2>/dev/null || true
    "
    log_info "Old core files removed"
fi

log_step "Step 8: Copying new Omeka S files to container..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would copy new release files to ${OMEKA_ROOT}"
else
    rm -rf "${EXTRACTED_DIR}/modules"/* 2>/dev/null || true
    rm -rf "${EXTRACTED_DIR}/themes"/* 2>/dev/null || true
    rm -rf "${EXTRACTED_DIR}/files"/* 2>/dev/null || true
    docker cp "${EXTRACTED_DIR}/." "${CONTAINER_ID}:${OMEKA_ROOT}/"
    log_info "New Omeka S files copied"
fi

log_step "Step 9: Restoring local.config.php and database.ini..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would restore config files from backup"
else
    docker compose exec -T php cp "${BACKUP_PATH}/config/local.config.php" "${OMEKA_ROOT}/config/local.config.php" 2>/dev/null || log_warn "local.config.php not found in backup"
    docker compose exec -T php cp "${BACKUP_PATH}/config/database.ini" "${OMEKA_ROOT}/config/database.ini" 2>/dev/null || log_warn "database.ini not found in backup"
    log_info "Config files restored"
fi

log_step "Step 10: Restoring modules..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would restore: ${BACKUP_PATH}/modules -> ${OMEKA_ROOT}/modules"
else
    docker compose exec -T php bash -c "cp -r ${BACKUP_PATH}/modules/* ${OMEKA_ROOT}/modules/ 2>/dev/null || true"
    log_info "Modules restored"
fi

log_step "Step 11: Restoring themes..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would restore: ${BACKUP_PATH}/themes -> ${OMEKA_ROOT}/themes"
else
    docker compose exec -T php bash -c "cp -r ${BACKUP_PATH}/themes/* ${OMEKA_ROOT}/themes/ 2>/dev/null || true"
    log_info "Themes restored"
fi

log_step "Step 12: Setting proper ownership and permissions..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would set: chown -R www-data:www-data ${OMEKA_ROOT}"
else
    docker compose exec -T php chown -R www-data:www-data "${OMEKA_ROOT}"
    docker compose exec -T php chmod -R 775 "${OMEKA_ROOT}/files"
    docker compose exec -T php chmod -R 775 "${OMEKA_ROOT}/modules"
    docker compose exec -T php chmod -R 775 "${OMEKA_ROOT}/themes"
    log_info "Permissions set"
fi

log_step "Step 13: Clearing Omeka S cache..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would remove: ${OMEKA_ROOT}/data/cache/*"
else
    docker compose exec -T php rm -rf "${OMEKA_ROOT}/data/cache/"* 2>/dev/null || true
    log_info "Cache cleared"
fi

log_step "Step 14: Restarting PHP container to clear OPcache..."
if [[ "$DRY_RUN" == true ]]; then
    echo "  Would run: docker compose restart php"
else
    docker compose restart php > /dev/null 2>&1
    sleep 5
    log_info "PHP container restarted"
fi

if [[ "$DRY_RUN" != true ]]; then
    rm -rf "${TEMP_DIR}"
fi

echo ""
echo "========================================"
if [[ "$DRY_RUN" == true ]]; then
    log_warn "DRY RUN COMPLETE - No changes were made"
else
    log_info "Omeka S updated to v${VERSION}!"
fi
echo "========================================"
echo ""

if [[ "$DRY_RUN" != true ]]; then
    log_info "Backup location: ${BACKUP_PATH}"
    echo ""
fi

log_info "Post-update checklist:"
echo "  1. Visit your Omeka S site in a browser"
echo "  2. Run any database migrations if prompted"
echo "  3. Check that all modules are working"
echo "  4. Verify themes are displaying correctly"
echo "  5. Test file/media access"
echo ""
log_info "To rollback if issues occur:"
echo "  docker compose exec php cp ${BACKUP_PATH}/config/local.config.php ${OMEKA_ROOT}/config/"
echo "  docker compose exec php cp ${BACKUP_PATH}/config/database.ini ${OMEKA_ROOT}/config/"
echo "  docker compose exec php cp -r ${BACKUP_PATH}/modules/* ${OMEKA_ROOT}/modules/"
echo "  docker compose exec php cp -r ${BACKUP_PATH}/themes/* ${OMEKA_ROOT}/themes/"
echo "  docker compose restart php"
