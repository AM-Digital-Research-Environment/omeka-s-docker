#!/bin/bash
set -e

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

# Configuration
OMEKA_ROOT="/var/www/html"
OMEKA_REPO="omeka/omeka-s"
OMEKA_VERSION="${OMEKA_VERSION:-latest}"

# Default modules to install (official Omeka S modules)
# Format: "ModuleName:repo:branch"
DEFAULT_MODULES=(
    "ActivityLog:omeka-s-modules/ActivityLog:master"
    "CSVImport:omeka-s-modules/CSVImport:develop"
    "DataCleaning:omeka-s-modules/DataCleaning:master"
    "DspaceConnector:omeka-s-modules/DspaceConnector:master"
    "FacetedBrowse:omeka-s-modules/FacetedBrowse:master"
    "FileSideload:omeka-s-modules/FileSideload:master"
    "ItemCarouselBlock:omeka-s-modules/ItemCarouselBlock:master"
    "Mapping:omeka-s-modules/Mapping:master"
    "NumericDataTypes:omeka-s-modules/NumericDataTypes:master"
)

# Default themes to install (official Omeka S themes)
# Format: "ThemeName:repo:branch"
DEFAULT_THEMES=(
    "Freedom:omeka-s-themes/Freedom:master"
    "Lively:omeka-s-themes/Lively:master"
)

# Function to get the latest release version from GitHub
get_latest_version() {
    local latest
    latest=$(curl -sL "https://api.github.com/repos/${OMEKA_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
    if [[ -z "$latest" ]]; then
        log_error "Failed to fetch latest version from GitHub"
        return 1
    fi
    echo "$latest"
}

# Function to install Omeka S
install_omeka() {
    local VERSION="$1"

    log_step "Installing Omeka S v${VERSION}..."

    # Download Omeka S
    local ARCHIVE_URL="https://github.com/${OMEKA_REPO}/releases/download/v${VERSION}/omeka-s-${VERSION}.zip"
    local TEMP_DIR=$(mktemp -d)

    log_info "Downloading Omeka S v${VERSION}..."
    if ! curl -sL "$ARCHIVE_URL" -o "${TEMP_DIR}/omeka-s.zip"; then
        log_error "Failed to download Omeka S"
        rm -rf "${TEMP_DIR}"
        return 1
    fi

    log_info "Extracting Omeka S..."
    unzip -q "${TEMP_DIR}/omeka-s.zip" -d "${TEMP_DIR}"

    # Find extracted directory
    EXTRACTED_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d -name "omeka-s*" | head -1)
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_error "Failed to find extracted Omeka S directory"
        rm -rf "${TEMP_DIR}"
        return 1
    fi

    # Copy files to web root
    log_info "Installing Omeka S files..."
    cp -r "${EXTRACTED_DIR}"/* "${OMEKA_ROOT}/"

    # Configure database connection
    log_info "Configuring database connection..."
    cat > "${OMEKA_ROOT}/config/database.ini" << EOF
user     = "${MYSQL_USER}"
password = "${MYSQL_PASSWORD}"
dbname   = "${MYSQL_DATABASE}"
host     = "${MYSQL_HOST}"
driver_options[1009] = false
EOF

    # Create local.config.php if it doesn't exist
    if [[ ! -f "${OMEKA_ROOT}/config/local.config.php" ]]; then
        log_info "Creating local.config.php..."
        cp "${OMEKA_ROOT}/config/local.config.php.dist" "${OMEKA_ROOT}/config/local.config.php"
    fi

    # Cleanup
    rm -rf "${TEMP_DIR}"

    log_info "Omeka S v${VERSION} installed successfully!"
    return 0
}

# Function to install a single module from GitHub
install_module() {
    local MODULE_NAME="$1"
    local REPO="$2"
    local BRANCH="${3:-master}"

    log_info "Installing module: $MODULE_NAME..."

    local TEMP_DIR=$(mktemp -d)
    local ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.zip"

    # Download the module
    if ! curl -sL "$ARCHIVE_URL" -o "${TEMP_DIR}/module.zip" 2>/dev/null; then
        # Try as a tag if branch fails
        ARCHIVE_URL="https://github.com/${REPO}/archive/refs/tags/${BRANCH}.zip"
        if ! curl -sL "$ARCHIVE_URL" -o "${TEMP_DIR}/module.zip" 2>/dev/null; then
            log_warn "Failed to download module $MODULE_NAME"
            rm -rf "${TEMP_DIR}"
            return 1
        fi
    fi

    # Extract the module
    unzip -q "${TEMP_DIR}/module.zip" -d "${TEMP_DIR}" 2>/dev/null

    # Find the extracted directory
    local EXTRACTED_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d ! -name "$(basename "${TEMP_DIR}")" | head -1)
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_warn "Failed to find extracted module directory for $MODULE_NAME"
        rm -rf "${TEMP_DIR}"
        return 1
    fi

    # Move to modules directory with correct name
    mv "$EXTRACTED_DIR" "${OMEKA_ROOT}/modules/${MODULE_NAME}"

    # Install composer dependencies if needed
    if [[ -f "${OMEKA_ROOT}/modules/${MODULE_NAME}/composer.json" ]]; then
        log_info "Installing composer dependencies for $MODULE_NAME..."
        (cd "${OMEKA_ROOT}/modules/${MODULE_NAME}" && composer install --no-dev --quiet 2>/dev/null) || true
    fi

    # Cleanup
    rm -rf "${TEMP_DIR}"

    log_info "Module $MODULE_NAME installed successfully!"
    return 0
}

# Function to install a single theme from GitHub
install_theme() {
    local THEME_NAME="$1"
    local REPO="$2"
    local BRANCH="${3:-master}"

    log_info "Installing theme: $THEME_NAME..."

    local TEMP_DIR=$(mktemp -d)
    local ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.zip"

    # Download the theme
    if ! curl -sL "$ARCHIVE_URL" -o "${TEMP_DIR}/theme.zip" 2>/dev/null; then
        # Try as a tag if branch fails
        ARCHIVE_URL="https://github.com/${REPO}/archive/refs/tags/${BRANCH}.zip"
        if ! curl -sL "$ARCHIVE_URL" -o "${TEMP_DIR}/theme.zip" 2>/dev/null; then
            log_warn "Failed to download theme $THEME_NAME"
            rm -rf "${TEMP_DIR}"
            return 1
        fi
    fi

    # Extract the theme
    unzip -q "${TEMP_DIR}/theme.zip" -d "${TEMP_DIR}" 2>/dev/null

    # Find the extracted directory
    local EXTRACTED_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d ! -name "$(basename "${TEMP_DIR}")" | head -1)
    if [[ -z "$EXTRACTED_DIR" ]]; then
        log_warn "Failed to find extracted theme directory for $THEME_NAME"
        rm -rf "${TEMP_DIR}"
        return 1
    fi

    # Move to themes directory with correct name
    mv "$EXTRACTED_DIR" "${OMEKA_ROOT}/themes/${THEME_NAME}"

    # Cleanup
    rm -rf "${TEMP_DIR}"

    log_info "Theme $THEME_NAME installed successfully!"
    return 0
}

# Function to install all default modules
install_default_modules() {
    log_step "Installing default modules..."

    for module_entry in "${DEFAULT_MODULES[@]}"; do
        # Parse format: "ModuleName:repo:branch"
        local MODULE_NAME="${module_entry%%:*}"
        local remainder="${module_entry#*:}"
        local REPO="${remainder%%:*}"
        local BRANCH="${remainder##*:}"

        # Skip if module already exists
        if [[ -d "${OMEKA_ROOT}/modules/${MODULE_NAME}" ]]; then
            log_info "Module $MODULE_NAME already exists, skipping..."
            continue
        fi

        install_module "$MODULE_NAME" "$REPO" "$BRANCH" || log_warn "Failed to install $MODULE_NAME, continuing..."
    done

    log_info "Default modules installation completed!"
}

# Function to install all default themes
install_default_themes() {
    log_step "Installing default themes..."

    for theme_entry in "${DEFAULT_THEMES[@]}"; do
        # Parse format: "ThemeName:repo:branch"
        local THEME_NAME="${theme_entry%%:*}"
        local remainder="${theme_entry#*:}"
        local REPO="${remainder%%:*}"
        local BRANCH="${remainder##*:}"

        # Skip if theme already exists
        if [[ -d "${OMEKA_ROOT}/themes/${THEME_NAME}" ]]; then
            log_info "Theme $THEME_NAME already exists, skipping..."
            continue
        fi

        install_theme "$THEME_NAME" "$REPO" "$BRANCH" || log_warn "Failed to install $THEME_NAME, continuing..."
    done

    log_info "Default themes installation completed!"
}

# Create required directories if they don't exist
log_step "Creating required directories..."
mkdir -p "${OMEKA_ROOT}/files"
mkdir -p "${OMEKA_ROOT}/sideload"
mkdir -p "${OMEKA_ROOT}/modules"
mkdir -p "${OMEKA_ROOT}/themes"
mkdir -p "${OMEKA_ROOT}/config"

# Check if Omeka S is already installed
if [[ ! -f "${OMEKA_ROOT}/application/Module.php" ]]; then
    log_info "Omeka S not found. Starting installation..."

    # Resolve version
    if [[ "$OMEKA_VERSION" == "latest" ]]; then
        log_info "Fetching latest version from GitHub..."
        OMEKA_VERSION=$(get_latest_version)
        if [[ $? -ne 0 ]]; then
            log_error "Failed to get latest version. Please set OMEKA_VERSION explicitly."
            exit 1
        fi
    fi

    # Remove 'v' prefix if present
    OMEKA_VERSION="${OMEKA_VERSION#v}"

    log_info "Will install Omeka S version: ${OMEKA_VERSION}"

    # Wait for MySQL to be ready (using PHP which supports caching_sha2_password natively)
    log_step "Waiting for MySQL to be ready..."
    MAX_TRIES=30
    TRIES=0
    until php -r "new PDO('mysql:host=${MYSQL_HOST};dbname=${MYSQL_DATABASE}', '${MYSQL_USER}', '${MYSQL_PASSWORD}');" 2>/dev/null; do
        TRIES=$((TRIES + 1))
        if [[ $TRIES -ge $MAX_TRIES ]]; then
            log_error "MySQL is not ready after ${MAX_TRIES} attempts"
            exit 1
        fi
        log_info "Waiting for MySQL... (attempt ${TRIES}/${MAX_TRIES})"
        sleep 2
    done
    log_info "MySQL is ready!"

    # Install Omeka S
    if ! install_omeka "$OMEKA_VERSION"; then
        log_error "Omeka S installation failed"
        exit 1
    fi
else
    log_info "Omeka S is already installed"
fi

# Always check and install missing default modules and themes
install_default_modules
install_default_themes

# Set proper permissions
log_step "Setting proper permissions..."
chown -R www-data:www-data "${OMEKA_ROOT}/modules"
chown -R www-data:www-data "${OMEKA_ROOT}/themes"
chown -R www-data:www-data "${OMEKA_ROOT}/files"
chown -R www-data:www-data "${OMEKA_ROOT}/sideload"
chown -R www-data:www-data "${OMEKA_ROOT}/config"
chmod 775 "${OMEKA_ROOT}/sideload"
chmod 775 "${OMEKA_ROOT}/files"
chmod 775 "${OMEKA_ROOT}/modules"
chmod 775 "${OMEKA_ROOT}/themes"

log_info "Entrypoint completed. Starting PHP-FPM..."

# Start php-fpm
exec "$@"
