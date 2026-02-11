#!/bin/bash
# ensure-composer.sh - Download Composer on first use if not already present.
# Called by docker-entrypoint.sh and module install/update scripts before
# any `composer install` invocation.
#
# Usage (inside container):
#   source /usr/local/bin/ensure-composer.sh
#   ensure_composer
#
# Usage (from host via docker compose):
#   docker compose exec -T php bash -c 'source /usr/local/bin/ensure-composer.sh && ensure_composer'

set -e

ensure_composer() {
    if command -v composer &>/dev/null; then
        return 0
    fi

    echo "[INFO] Composer not found, downloading..."
    local EXPECTED_CHECKSUM
    EXPECTED_CHECKSUM="$(curl -sSL https://composer.github.io/installer.sig)"

    curl -sSL https://getcomposer.org/installer -o /tmp/composer-setup.php

    local ACTUAL_CHECKSUM
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"

    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        echo "[ERROR] Composer installer checksum mismatch" >&2
        rm -f /tmp/composer-setup.php
        return 1
    fi

    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    rm -f /tmp/composer-setup.php
    echo "[INFO] Composer installed successfully"
}
