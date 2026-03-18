FROM alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS toolfetcher

ARG VERSION=0.9.3
ARG SHA=9392e779e25b9cfe0e8c1d559d8f5347863f3b0ab56d7a37d107f17f09bb247b

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache curl \
    && curl -sL https://github.com/GhentCDH/Omeka-S-Cli/releases/download/v${VERSION}/omeka-s-cli.phar -o /omeka-s-cli.phar \
    && echo "${SHA} /omeka-s-cli.phar" | sha256sum -c -

FROM php:8.4-fpm AS runtime

ARG OMEKA_ROOT=/var/www/html
ARG OMEKA_VERSION=4.2.0

# Install only runtime shared libraries (no -dev headers, no compilers)
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    libgmp10 \
    libtidy58 \
    ghostscript \
    libvips-tools \
    poppler-utils \
    # Runtime tools needed by entrypoint and module scripts
    curl \
    git \
    wget \
    unzip \
    # Healthcheck dependency
    libfcgi-bin \
    # Privilege dropping (entrypoint runs as root, drops to www-data)
    gosu \
    && rm -rf /var/lib/apt/lists/* \
    # Verify gosu works
    && gosu nobody true

# Install PHP extensions
RUN --mount=type=bind,from=ghcr.io/mlocati/php-extension-installer:latest,source=/usr/bin/install-php-extensions,target=/usr/local/bin/install-php-extensions \
    install-php-extensions \
    bcmath \
    exif \
    gd \
    gettext \
    gmp \
    imagick \
    intl \
    mysqli \
    opcache \
    pdo_mysql \
    sockets \
    tidy \
    xsl \
    zip
        
# Build APCu
RUN pecl install apcu && \
    docker-php-ext-enable apcu

# Set PHP configuration
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && sed -i \
        -e 's/memory_limit = 128M/memory_limit = 1024M/' \
        -e 's/upload_max_filesize = 2M/upload_max_filesize = 100M/' \
        -e 's/post_max_size = 8M/post_max_size = 100M/' \
        -e 's/max_execution_time = 30/max_execution_time = 300/' \
        "$PHP_INI_DIR/php.ini"

# Configure OPcache with optimized settings
RUN { \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.interned_strings_buffer=16'; \
    echo 'opcache.max_accelerated_files=10000'; \
    echo 'opcache.revalidate_freq=60'; \
    echo 'opcache.fast_shutdown=1'; \
    echo 'opcache.enable_cli=1'; \
    echo 'opcache.enable_file_override=1'; \
    echo 'opcache.validate_timestamps=0'; \
    echo 'opcache.jit=1255'; \
    echo 'opcache.jit_buffer_size=50M'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Configure realpath cache (reduces stat() calls with many modules)
RUN { \
    echo 'realpath_cache_size=4096K'; \
    echo 'realpath_cache_ttl=600'; \
    } > /usr/local/etc/php/conf.d/realpath-cache.ini

# Configure APCu
RUN { \
    echo 'extension=apcu.so'; \
    echo 'apc.enabled=1'; \
    echo 'apc.shm_size=256M'; \
    echo 'apc.ttl=7200'; \
    } > /usr/local/etc/php/conf.d/docker-php-ext-apcu.ini

# Create required directories and set permissions
RUN mkdir -p "$OMEKA_ROOT/files" \
    "$OMEKA_ROOT/sideload" \
    "$OMEKA_ROOT/modules" \
    "$OMEKA_ROOT/themes" \
    "$OMEKA_ROOT/config" \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 775 /var/www/html

# Install php-fpm-healthcheck script for container health monitoring
RUN curl -o /usr/local/bin/php-fpm-healthcheck \
    https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
    && chmod +x /usr/local/bin/php-fpm-healthcheck

# Enable PHP-FPM status page for healthcheck
RUN set -xe && echo "pm.status_path = /status" >> /usr/local/etc/php-fpm.d/zz-docker.conf

# PHP-FPM pool settings are generated dynamically in docker-entrypoint.sh
# to support runtime configuration via PHP_PM_* environment variables

WORKDIR /var/www/html

COPY --from=toolfetcher --chmod=+x /omeka-s-cli.phar /usr/local/bin/omeka-s-cli



# TODO: document usage of the "latest" sentinel value
RUN if [ "$OMEKA_VERSION" = "latest" ]; then \
    omeka-s-cli core:download "$OMEKA_ROOT"; \
    else \
    omeka-s-cli core:download "$OMEKA_ROOT" "$OMEKA_VERSION"; \
    fi

RUN omeka-s-cli theme:download --base-path "$OMEKA_ROOT" gh:omeka-s-themes/default \
    && omeka-s-cli theme:download --base-path "$OMEKA_ROOT" gh:omeka-s-themes/freedom \
    && omeka-s-cli theme:download --base-path "$OMEKA_ROOT" gh:omeka-s-themes/lively

# Copy helper scripts and entrypoint, fix line endings (Windows compatibility)
COPY ensure-composer.sh /usr/local/bin/
COPY docker-entrypoint.sh /usr/local/bin/
RUN sed -i 's/\r$//' /usr/local/bin/ensure-composer.sh \
    && sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /usr/local/bin/ensure-composer.sh \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

# Set recommended PHP.ini settings
RUN echo "date.timezone = Europe/Berlin" >> /usr/local/etc/php/conf.d/docker-php-timezone.ini

# No USER directive — entrypoint runs as root for setup, then drops to
# www-data via gosu before starting php-fpm.

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
