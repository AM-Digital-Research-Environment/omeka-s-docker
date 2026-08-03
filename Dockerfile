FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS toolfetcher

ARG VERSION=0.9.3
ARG SHA=9392e779e25b9cfe0e8c1d559d8f5347863f3b0ab56d7a37d107f17f09bb247b

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache curl \
    && curl --fail --show-error --location \
        https://github.com/GhentCDH/Omeka-S-Cli/releases/download/v${VERSION}/omeka-s-cli.phar \
        --output /omeka-s-cli.phar \
    && echo "${SHA} /omeka-s-cli.phar" | sha256sum -c -

FROM php:8.5.9-fpm-trixie@sha256:f56f4a81de6cd33ddfd6e99352889a53c94c3ffccce89e494563845a1c8ba75a AS runtime

ARG OMEKA_ROOT=/var/www/html
ARG OMEKA_VERSION=4.2.1
ARG EXTRA_MODULES_FILE=_docker/empty-modules.txt
ARG EXTRA_THEMES_FILE=_docker/empty-themes.txt
ARG EXTRA_MODULES=""
ARG EXTRA_THEMES=""
ARG ENABLE_IIIF=false
ARG OMEKA_ASSET_REFRESH=stable

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
RUN --mount=type=bind,from=ghcr.io/mlocati/php-extension-installer:2.11.1@sha256:bd9ea77afcbc8e55e58d55ca9a39153925367e972827d2f648c949fd0e44aaca,source=/usr/bin/install-php-extensions,target=/usr/local/bin/install-php-extensions \
    install-php-extensions \
    apcu-5.1.28 \
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

# The Compose healthcheck probes this endpoint directly with cgi-fcgi. Keeping
# the probe local avoids downloading and executing a floating script from a
# third-party repository during every image build.
RUN echo "pm.status_path = /status" >> /usr/local/etc/php-fpm.d/zz-docker.conf

# Runtime pool tuning is written under /run (tmpfs) because the application
# container's root filesystem is read-only. PHP-FPM loads this second include
# after its image-baked pool configuration.
RUN echo "include=/run/php-fpm/*.conf" >> /usr/local/etc/php-fpm.conf

RUN chown -R www-data:www-data "$OMEKA_ROOT" \
    && chmod -R u=rwX,go=rX "$OMEKA_ROOT" \
    && chown www-data:www-data /usr/local/etc/php-fpm.d \
    # omeka-s-cli caches into $HOME/.cache, which is /var/www for www-data
    && mkdir -p /var/www/.cache \
    && chown www-data:www-data /var/www/.cache

USER www-data

WORKDIR /var/www/html

COPY --from=toolfetcher --chmod=0755 /omeka-s-cli.phar /usr/local/bin/omeka-s-cli
COPY --from=composer/composer:2.10.2-bin@sha256:cf313f79f608ebab80220796327f341ae663b9fa8065c73c6148c9b67f0b13b3 /composer /usr/bin/composer

# TODO: document usage of the "latest" sentinel value
RUN if [ "$OMEKA_VERSION" = "latest" ]; then \
        omeka-s-cli core:download "$OMEKA_ROOT"; \
    else \
        omeka-s-cli core:download "$OMEKA_ROOT" "$OMEKA_VERSION"; \
    fi

# Keep deployment configuration immutable/read-only while the database secret
# is regenerated into /run/omeka on every start. The Compose bind lets a
# deployment provide a reviewed local.config.php without making the code tree
# writable.
COPY --chown=www-data:www-data _docker/local.config.php ${OMEKA_ROOT}/config/local.config.php
RUN rm -f "${OMEKA_ROOT}/config/database.ini" \
    && ln -s /run/omeka/database.ini "${OMEKA_ROOT}/config/database.ini"

COPY --chown=www-data:www-data _docker/default-modules.txt /tmp/default-modules.txt
COPY --chown=www-data:www-data _docker/extra-modules.txt /tmp/operator-modules.txt

# Deployment overlays can bake additional modules into the image by pointing
# this build arg at another modules file (same omeka-s-cli syntax), e.g.
# compose.amira.yml sets it to deploy/amira/modules.txt. The default is an
# empty placeholder so plain builds add nothing.
COPY --chown=www-data:www-data ${EXTRA_MODULES_FILE} /tmp/deployment-modules.txt

RUN echo "Asset refresh token: ${OMEKA_ASSET_REFRESH}" \
    && while IFS= read -r mod || [ -n "$mod" ]; do \
        mod=$(printf '%s' "$mod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); \
        case "$mod" in ''|'#'*) continue ;; esac; \
        omeka-s-cli module:download --base-path "$OMEKA_ROOT" "$mod"; \
    done < /tmp/default-modules.txt \
    && for list in /tmp/operator-modules.txt /tmp/deployment-modules.txt; do \
        while IFS= read -r mod || [ -n "$mod" ]; do \
            mod=$(printf '%s' "$mod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); \
            case "$mod" in ''|'#'*) continue ;; esac; \
            omeka-s-cli module:download --base-path "$OMEKA_ROOT" --force "$mod"; \
        done < "$list"; \
    done \
    && if [ -n "$EXTRA_MODULES" ]; then \
        while IFS= read -r mod || [ -n "$mod" ]; do \
            mod=$(printf '%s' "$mod" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); \
            [ -z "$mod" ] || omeka-s-cli module:download --base-path "$OMEKA_ROOT" --force "$mod"; \
        done < <(printf '%s' "$EXTRA_MODULES" | tr ',' '\n'); \
    fi \
    && if [ "$ENABLE_IIIF" = "true" ]; then \
        for mod in \
            gh:Daniel-KM/Omeka-S-module-IiifServer \
            gh:Daniel-KM/Omeka-S-module-ImageServer \
            gh:Daniel-KM/Omeka-S-module-Mirador; do \
            omeka-s-cli module:download --base-path "$OMEKA_ROOT" --force "$mod"; \
        done; \
    fi

# Local source directories are the deterministic escape hatch for private or
# migrated extensions. Each directory replaces a same-named downloaded module
# or theme rather than merging stale files into it.
COPY --chown=www-data:www-data _docker/local-modules/ /tmp/local-modules/
RUN shopt -s nullglob \
    && for module_dir in /tmp/local-modules/*/; do \
        module_name=$(basename "$module_dir"); \
        rm -rf "${OMEKA_ROOT}/modules/${module_name}"; \
        cp -a "$module_dir" "${OMEKA_ROOT}/modules/${module_name}"; \
    done

COPY --chown=www-data:www-data _docker/extra-themes.txt /tmp/operator-themes.txt

# Deployment overlays add their themes through this build arg, e.g.
# compose.amira.yml points it at deploy/amira/themes.txt. The default is an
# empty placeholder so plain builds add nothing.
COPY --chown=www-data:www-data ${EXTRA_THEMES_FILE} /tmp/deployment-themes.txt

# A manifest line is "<omeka-s-cli URI> [target-directory]". The optional second
# field exists because omeka-s-cli derives the theme directory from theme.ini's
# "name" field, while Omeka's site rows select a theme by directory name — so a
# theme whose display name does not sanitise back to the expected directory
# (e.g. "Africa Multiple — DRE" -> Africa_Multiple_____DRE, needed as DRE-theme)
# would silently detach every site using it. Renaming the freshly created
# directory keeps such themes declarative instead of vendored into this repo.
RUN <<'THEMES'
set -euo pipefail

download_theme() {
    local uri="$1" target="${2:-}" before after created
    before="$(ls -1 "${OMEKA_ROOT}/themes" | sort)"
    omeka-s-cli theme:download --base-path "$OMEKA_ROOT" --force "$uri"
    [ -n "$target" ] || return 0
    after="$(ls -1 "${OMEKA_ROOT}/themes" | sort)"
    created="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
    if [ -d "${OMEKA_ROOT}/themes/${target}" ] && [ -z "$created" ]; then
        return 0
    fi
    if [ "$(printf '%s\n' "$created" | grep -c .)" != 1 ]; then
        echo "ERROR: '$uri' did not create exactly one theme directory (got: ${created:-none})." >&2
        return 1
    fi
    [ "$created" = "$target" ] || mv "${OMEKA_ROOT}/themes/${created}" "${OMEKA_ROOT}/themes/${target}"
}

read_manifest() {
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$line" in ''|'#'*) continue ;; esac
        # shellcheck disable=SC2086 # deliberate split into URI + optional target
        download_theme $line
    done < "$1"
}

download_theme gh:omeka-s-themes/freedom
download_theme gh:omeka-s-themes/lively
read_manifest /tmp/operator-themes.txt
read_manifest /tmp/deployment-themes.txt

if [ -n "${EXTRA_THEMES:-}" ]; then
    while IFS= read -r theme || [ -n "$theme" ]; do
        theme="$(printf '%s' "$theme" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # shellcheck disable=SC2086 # same "<uri> [target]" syntax as the manifests
        [ -z "$theme" ] || download_theme $theme
    done < <(printf '%s' "$EXTRA_THEMES" | tr ',' '\n')
fi
THEMES

COPY --chown=www-data:www-data _docker/local-themes/ /tmp/local-themes/
RUN shopt -s nullglob \
    && for theme_dir in /tmp/local-themes/*/; do \
        theme_name=$(basename "$theme_dir"); \
        rm -rf "${OMEKA_ROOT}/themes/${theme_name}"; \
        cp -a "$theme_dir" "${OMEKA_ROOT}/themes/${theme_name}"; \
    done \
    # Vendor every module that declares dependencies but does not ship them.
    # Presence of composer.lock must NOT gate this: modules that gitignore their
    # lock file (DRESearch, DRESeo) still require vendor/autoload.php at runtime,
    # and skipping them leaves the module fatally broken at boot. composer
    # install resolves from composer.json when no lock is present.
    && for composer_json in "${OMEKA_ROOT}"/modules/*/composer.json; do \
        [ -f "$composer_json" ] || continue; \
        module_dir=$(dirname "$composer_json"); \
        [ -d "$module_dir/vendor" ] || composer install \
            --working-dir "$module_dir" --no-dev --no-interaction \
            --prefer-dist --optimize-autoloader; \
    done

# Persist PHP sessions on a dedicated volume (mounted in docker-compose.yml)
# instead of the default tmpfs /tmp, so container restarts/recreates no longer
# wipe everyone's login session and CSRF tokens. The directory is created here
# owned by www-data so the fresh named volume inherits that ownership on first
# mount — the running container drops CAP_CHOWN and cannot fix it afterwards.
USER root
RUN mkdir -p /var/lib/php-sessions /run/omeka /run/php-fpm \
    && chown www-data:www-data /var/lib/php-sessions \
    && chown www-data:www-data /run/omeka /run/php-fpm \
    && chmod 700 /var/lib/php-sessions /run/omeka /run/php-fpm
COPY <<EOF /usr/local/etc/php/conf.d/92-sessions.ini
session.save_path = "/var/lib/php-sessions"
EOF
USER www-data

COPY --chown=www-data:www-data _docker/vocabularies/ /usr/local/share/omeka-vocabs/

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/

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

# nginx serves the exact static assets baked into the PHP image. Keeping both
# targets in one Dockerfile guarantees core/module/theme assets change together
# while media remains a separately mounted read-only volume.
FROM nginx:1.30.4-alpine@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46 AS web

COPY --from=runtime --chown=nginx:nginx /var/www/html /var/www/html
