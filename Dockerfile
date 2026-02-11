# ==============================================================================
# Stage 1: builder — compile ImageMagick & PHP extensions with dev headers
# ==============================================================================
FROM php:8.5-fpm AS builder

# Pin ImageMagick version for reproducible builds
ARG IMAGEMAGICK_VERSION=7.1.2-13

# Install build-time dependencies (dev headers, compilers, tools)
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    libwebp-dev \
    libxml2-dev \
    libxslt1-dev \
    libzip-dev \
    libmagickwand-dev \
    libgmp-dev \
    libtidy-dev \
    libicu-dev \
    libopenjp2-7-dev \
    pkg-config \
    git \
    curl \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Compile ImageMagick from source (pinned version)
RUN set -eux; \
    cd /tmp && \
    wget "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGEMAGICK_VERSION}.tar.gz" -O "ImageMagick-${IMAGEMAGICK_VERSION}.tar.gz" && \
    tar xf "ImageMagick-${IMAGEMAGICK_VERSION}.tar.gz" && \
    cd "ImageMagick-${IMAGEMAGICK_VERSION}" && \
    ./configure --with-modules --enable-shared --with-webp --with-openjp2 --with-gslib --with-gs-font-dir=/usr/share/fonts/type1/gsfonts && \
    make -j$(nproc) && \
    make install && \
    ldconfig /usr/local/lib && \
    cd .. && \
    rm -rf ImageMagick*

# Build PHP Imagick extension from PECL source
RUN set -eux; \
    mkdir -p /usr/local/etc/php/conf.d && \
    pecl channel-update pecl.php.net && \
    mkdir -p /tmp/imagick && \
    cd /tmp/imagick && \
    pecl download imagick && \
    tar xf imagick-*.tgz && \
    cd imagick-* && \
    phpize && \
    ./configure && \
    make -j$(nproc) && \
    make install && \
    cd / && \
    rm -rf /tmp/imagick && \
    echo "extension=imagick.so" > /usr/local/etc/php/conf.d/imagick.ini && \
    php -r "if (class_exists('Imagick')) echo 'Imagick installed successfully';"

# Configure and build PHP extensions
# Omeka S core needs: gd, intl, pdo_mysql, xml/xsl, zip
# Useful extras: bcmath, exif, gettext, gmp, mysqli, opcache, sockets, tidy
#
# Removed (not needed by Omeka S): shmop, sysvmsg, sysvsem, sysvshm, calendar, soap, ldap
# To re-add any of these, append them to the docker-php-ext-install list below
# and add the corresponding -dev package (e.g. libldap2-dev for ldap).
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp

RUN docker-php-ext-install -j$(nproc) \
    bcmath \
    exif \
    gd \
    gettext \
    gmp \
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


# ==============================================================================
# Stage 2: runtime — lean production image
# ==============================================================================
FROM php:8.5-fpm AS runtime

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

# Copy compiled PHP extensions and config from builder
COPY --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# Copy ImageMagick binaries and libraries from builder
COPY --from=builder /usr/local/bin/magick /usr/local/bin/magick
COPY --from=builder /usr/local/lib/libMagick* /usr/local/lib/
COPY --from=builder /usr/local/etc/ImageMagick-7/ /usr/local/etc/ImageMagick-7/
RUN ldconfig /usr/local/lib \
    && ln -sf /usr/local/bin/magick /usr/local/bin/convert \
    && ln -sf /usr/local/bin/magick /usr/local/bin/identify

# Configure ImageMagick policies
RUN set -eux; \
    mkdir -p /usr/local/etc/ImageMagick-7 && \
    { \
        echo '<?xml version="1.0" encoding="UTF-8"?>'; \
        echo '<policymap>'; \
        echo '  <policy domain="resource" name="memory" value="256MiB"/>'; \
        echo '  <policy domain="resource" name="map" value="512MiB"/>'; \
        echo '  <policy domain="resource" name="width" value="16KP"/>'; \
        echo '  <policy domain="resource" name="height" value="16KP"/>'; \
        echo '  <policy domain="coder" rights="read|write" pattern="PDF"/>'; \
        echo '  <policy domain="coder" rights="read|write" pattern="PS"/>'; \
        echo '  <policy domain="coder" rights="read|write" pattern="EPS"/>'; \
        echo '  <policy domain="coder" rights="read|write" pattern="XPS"/>'; \
        echo '  <policy domain="delegate" rights="read|write" pattern="gs"/>'; \
        echo '</policymap>'; \
    } > /usr/local/etc/ImageMagick-7/policy.xml

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
