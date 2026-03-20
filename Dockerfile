FROM php:8.4-fpm AS runtime

# Install only runtime shared libraries (no -dev headers, no compilers)
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    libfreetype6 \
    libjpeg62-turbo \
    libpng16-16t64 \
    libwebp7 \
    libxml2 \
    libxslt1.1 \
    libzip5 \
    libgmp10 \
    libtidy58 \
    libicu76 \
    libopenjp2-7 \
    ghostscript \
    libvips-tools \
    poppler-utils \
    # Runtime tools needed by entrypoint and module scripts
    curl \
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
RUN mkdir -p /var/www/html/files \
    /var/www/html/sideload \
    /var/www/html/modules \
    /var/www/html/themes \
    /var/www/html/config \
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
