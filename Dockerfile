FROM php:8.4-fpm

# Install system dependencies
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
    libldap2-dev \
    libtidy-dev \
    pkg-config \
    unzip \
    git \
    curl \
    wget \
    lsb-release \
    gnupg \
    xz-utils \
    ghostscript \
    libvips-tools \
    poppler-utils \
    libicu-dev \
    libfcgi-bin \
    && rm -rf /var/lib/apt/lists/*

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Install and configure ImageMagick
RUN set -eux; \
    cd /tmp && \
    wget https://imagemagick.org/archive/ImageMagick.tar.gz && \
    tar xf ImageMagick.tar.gz && \
    cd ImageMagick-* && \
    ./configure --with-modules --enable-shared --with-webp --with-openjp2 --with-gslib --with-gs-font-dir=/usr/share/fonts/type1/gsfonts && \
    make -j$(nproc) && \
    make install && \
    ldconfig /usr/local/lib && \
    cd .. && \
    rm -rf ImageMagick*

# Configure ImageMagick policies
RUN set -eux; \
    mkdir -p /etc/ImageMagick-6 && \
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
    } > /etc/ImageMagick-6/policy.xml

# Install PHP Imagick extension
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

# Configure and install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-configure ldap

# Install PHP extensions (pspell removed - not available in PHP 8.4)
RUN docker-php-ext-install -j$(nproc) \
    bcmath \
    calendar \
    exif \
    gd \
    gettext \
    gmp \
    intl \
    ldap \
    mysqli \
    opcache \
    pdo_mysql \
    shmop \
    soap \
    sockets \
    sysvmsg \
    sysvsem \
    sysvshm \
    tidy \
    xsl \
    zip

# Install APCu
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
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

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

# Configure PHP-FPM pool settings (optimized for 4GB container limit)
RUN { \
    echo '[www]'; \
    echo 'pm = dynamic'; \
    echo 'pm.max_children = 10'; \
    echo 'pm.start_servers = 3'; \
    echo 'pm.min_spare_servers = 2'; \
    echo 'pm.max_spare_servers = 5'; \
    echo 'pm.max_requests = 500'; \
    echo 'pm.process_idle_timeout = 10s'; \
    echo 'request_terminate_timeout = 300s'; \
    } > /usr/local/etc/php-fpm.d/zzz-omeka-pool.conf

WORKDIR /var/www/html

# Copy entrypoint script and fix line endings (for Windows compatibility)
COPY docker-entrypoint.sh /usr/local/bin/
RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

# Set recommended PHP.ini settings
RUN echo "date.timezone = Europe/Berlin" >> /usr/local/etc/php/conf.d/docker-php-timezone.ini

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
