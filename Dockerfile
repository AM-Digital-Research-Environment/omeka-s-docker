FROM alpine:3.23.4@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11 AS toolfetcher

ARG VERSION=0.9.3
ARG SHA=9392e779e25b9cfe0e8c1d559d8f5347863f3b0ab56d7a37d107f17f09bb247b

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache curl \
    && curl -sL https://github.com/GhentCDH/Omeka-S-Cli/releases/download/v${VERSION}/omeka-s-cli.phar -o /omeka-s-cli.phar \
    && echo "${SHA} /omeka-s-cli.phar" | sha256sum -c -

FROM php:8.5-fpm AS runtime

ARG OMEKA_ROOT=/var/www/html
ARG OMEKA_VERSION=4.2.1

# We're never going to be able to give feedback to apt during build
ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    libgmp10 \
    libtidy58 \
    ghostscript \
    imagemagick \
    libvips-tools \
    poppler-utils \
    # Runtime tools needed by entrypoint and module scripts
    curl \
    git \
    wget \
    unzip \
    # Healthcheck dependency
    libfcgi-bin \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

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
        -e 's/memory_limit = 128M/memory_limit = 512M/' \
        -e 's/upload_max_filesize = 2M/upload_max_filesize = 100M/' \
        -e 's/post_max_size = 8M/post_max_size = 100M/' \
        -e 's/max_execution_time = 30/max_execution_time = 300/' \
    "$PHP_INI_DIR/php.ini"

COPY <<EOF /usr/local/etc/php/conf.d/90-opcache.ini
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=1
opcache.enable_file_override=1
opcache.validate_timestamps=0
opcache.jit=1255
opcache.jit_buffer_size=50M
EOF

COPY <<EOF /usr/local/etc/php/conf.d/91-realpath-cache.ini
realpath_cache_size=4096K
realpath_cache_ttl=600
EOF

COPY <<EOF /usr/local/etc/php/conf.d/docker-php-ext-apcu.ini
extension=apcu.so
apc.enabled=1
apc.shm_size=256M
apc.ttl=7200
EOF

# Install php-fpm-healthcheck script for container health monitoring
RUN curl -o /usr/local/bin/php-fpm-healthcheck \
    https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck \
    && chmod +x /usr/local/bin/php-fpm-healthcheck \
    && echo "pm.status_path = /status" >> /usr/local/etc/php-fpm.d/zz-docker.conf

RUN chown -R www-data:www-data "$OMEKA_ROOT" \
    && chmod -R 775 "$OMEKA_ROOT" \
    && chown www-data:www-data /usr/local/etc/php-fpm.d \
    # omeka-s-cli caches into $HOME/.cache, which is /var/www for www-data
    && mkdir -p /var/www/.cache \
    && chown www-data:www-data /var/www/.cache

USER www-data

WORKDIR /var/www/html

COPY --from=toolfetcher --chmod=0755 /omeka-s-cli.phar /usr/local/bin/omeka-s-cli
COPY --from=composer/composer:2-bin /composer /usr/bin/composer

# TODO: document usage of the "latest" sentinel value
RUN if [ "$OMEKA_VERSION" = "latest" ]; then \
        omeka-s-cli core:download "$OMEKA_ROOT"; \
    else \
        omeka-s-cli core:download "$OMEKA_ROOT" "$OMEKA_VERSION"; \
    fi

COPY --chown=www-data:www-data _docker/default-modules.txt /tmp/default-modules.txt

# Deployment overlays can bake additional modules into the image by pointing
# this build arg at another modules file (same omeka-s-cli syntax), e.g.
# compose.amira.yml sets it to deploy/amira/modules.txt. The default is an
# empty placeholder so plain builds add nothing.
ARG EXTRA_MODULES_FILE=_docker/empty-modules.txt
COPY --chown=www-data:www-data ${EXTRA_MODULES_FILE} /tmp/extra-modules.txt

RUN for list in /tmp/default-modules.txt /tmp/extra-modules.txt; do \
        while IFS= read -r mod || [ -n "$mod" ]; do \
            # strip comments, trim spaces at beginning/end of line
            mod=$(echo "$mod" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//'); \
            # skip empty lines
            [ -z "$mod" ] && continue; \
            omeka-s-cli module:download --base-path "$OMEKA_ROOT" "$mod"; \
        done < "$list"; \
    done

RUN omeka-s-cli theme:download --base-path "$OMEKA_ROOT" gh:omeka-s-themes/freedom \
    && omeka-s-cli theme:download --base-path "$OMEKA_ROOT" gh:omeka-s-themes/lively

# Persist PHP sessions on a dedicated volume (mounted in docker-compose.yml)
# instead of the default tmpfs /tmp, so container restarts/recreates no longer
# wipe everyone's login session and CSRF tokens. The directory is created here
# owned by www-data so the fresh named volume inherits that ownership on first
# mount — the running container drops CAP_CHOWN and cannot fix it afterwards.
USER root
RUN mkdir -p /var/lib/php-sessions \
    && chown www-data:www-data /var/lib/php-sessions \
    && chmod 700 /var/lib/php-sessions
COPY <<EOF /usr/local/etc/php/conf.d/92-sessions.ini
session.save_path = "/var/lib/php-sessions"
EOF
USER www-data

COPY --chown=www-data:www-data _docker/vocabularies/ /usr/local/share/omeka-vocabs/

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/
COPY --chmod=0755 ensure-composer.sh /usr/local/bin/

# Composer's default cache dir is $HOME/.composer (= /var/www/.composer), which
# is root-owned and unwritable by www-data — so composer would run cacheless,
# re-download all package metadata on every run, and intermittent truncated
# fetches surface as bogus dependency conflicts. Redirect it to the
# www-data-owned /var/www/.cache created during the chown step above. Placed
# here (after the omeka-s-cli download layers) so toggling it never busts the
# expensive core/module/theme download cache.
ENV COMPOSER_CACHE_DIR=/var/www/.cache/composer

ENTRYPOINT ["docker-entrypoint.sh"]

CMD ["php-fpm"]
