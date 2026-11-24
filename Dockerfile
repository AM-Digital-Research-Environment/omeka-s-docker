FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS toolfetcher

ARG VERSION=0.20.0
ARG SHA=1eab4f68a8f55a34fc848c1664bc910ef49dff4f1f2e8d70947cf2d6b81adb43

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache curl \
    && curl --fail --show-error --location --retry 5 --retry-all-errors \
        https://github.com/GhentCDH/Omeka-S-Cli/releases/download/v${VERSION}/omeka-s-cli.phar \
        --output /omeka-s-cli.phar \
    && echo "${SHA} /omeka-s-cli.phar" | sha256sum -c -

# Build-time tool images, declared as named stages purely so Dependabot tracks
# them. Its Docker parser only reads `FROM` lines — an image named inline in
# `COPY --from=` or `RUN --mount=from=` is invisible to it, so those pins would
# silently never be offered an update. Referencing the stage name below keeps
# one `FROM` line per tool as the single place a bump has to land.
FROM ghcr.io/mlocati/php-extension-installer:2.13.2@sha256:4fd45396c16685266d32bf147a24ecd5e81029d3820295895bf4a90131190ac9 AS php-extension-installer
FROM composer/composer:2.11.1-bin@sha256:56a1b0a72bacd78079e3fa49a49e7bf58326365753415c99385ea2b08bded0a5 AS composer-bin

FROM php:8.5.12-fpm-trixie@sha256:baf3ea13a8207fa18e1011bad1016e8b5e59fc974c6966d0efa6f36a16f875f0 AS runtime

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
RUN --mount=type=bind,from=php-extension-installer,source=/usr/bin/install-php-extensions,target=/usr/local/bin/install-php-extensions \
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

# Production php.ini. The memory_limit raise here is build-time headroom for
# the omeka-s-cli and composer runs below; at runtime uploads.ini (baked in
# near the end of this stage and bind-mounted over by docker-compose.yml) is
# the single source of truth for memory, upload and execution-time limits.
# The other runtime tuning files are baked in after the download layers too,
# so adjusting them never re-downloads Omeka core, modules and themes.
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && sed -i -e 's/^memory_limit = 128M$/memory_limit = 512M/' "$PHP_INI_DIR/php.ini" \
    && grep -qx 'memory_limit = 512M' "$PHP_INI_DIR/php.ini"

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
COPY --from=composer-bin /composer /usr/bin/composer

# OMEKA_VERSION=latest resolves to whatever is current at build time, which is by
# definition untested against this image; the entrypoint warns when it sees it.
# Documented under "Settings" in README.md.
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
COPY _docker/vendor-security-floors.txt /tmp/vendor-security-floors.txt
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
    done \
    # Raise vendored packages a module release ships at a known-vulnerable
    # version (see the manifest for syntax and when to drop entries).
    && while read -r module_name floor; do \
        case "$module_name" in ''|'#'*) continue ;; esac; \
        module_dir="${OMEKA_ROOT}/modules/${module_name}"; \
        package="${floor%%:*}"; \
        [ -f "$module_dir/composer.lock" ] && grep -q "\"name\": \"${package}\"" "$module_dir/composer.lock" || continue; \
        composer update "$package" --with "$floor" \
            --working-dir "$module_dir" --no-dev --no-interaction \
            --prefer-dist --optimize-autoloader || exit 1; \
    done < /tmp/vendor-security-floors.txt

# Persist PHP sessions on a dedicated volume (mounted in docker-compose.yml)
# instead of the default tmpfs /tmp, so container restarts/recreates no longer
# wipe everyone's login session and CSRF tokens. The directory is created here
# owned by www-data so the fresh named volume inherits that ownership on first
# mount — the running container drops CAP_CHOWN and cannot fix it afterwards.
# /var/lib/omeka is the same pattern for deployment data that must live OUTSIDE
# the document root. A module whose generated state is served through Omeka
# rather than by nginx mounts a private volume under it — see
# DRE_VISUALIZATIONS_DATA_DIR in compose.amira.yml.
#
# The LEAF directory of every such mount must exist here, www-data-owned.
# Docker seeds a fresh named volume's ownership from the image path it is
# mounted at; where that path does not exist it creates the mountpoint
# root-owned 0755 instead, and the container cannot repair it afterwards
# because it runs as www-data with CAP_CHOWN dropped. Creating only the parent
# is not enough — that was the actual failure when this volume was introduced.
USER root
RUN mkdir -p /var/lib/php-sessions /var/lib/omeka/dre-visualizations /run/omeka /run/php-fpm \
    && chown -R www-data:www-data /var/lib/php-sessions /var/lib/omeka \
    && chown www-data:www-data /run/omeka /run/php-fpm \
    && chmod 700 /var/lib/php-sessions /var/lib/omeka /var/lib/omeka/dre-visualizations \
    && chmod 700 /run/omeka /run/php-fpm
COPY <<EOF /usr/local/etc/php/conf.d/92-sessions.ini
session.save_path = "/var/lib/php-sessions"
EOF

# Runtime PHP tuning. Kept after the download layers on purpose: changing a
# value here rebuilds only the cheap layers below.
#
# uploads.ini is baked in as the default and docker-compose.yml bind-mounts the
# same repository file over it, so the image default and the operator override
# are one file and cannot disagree; an image run without the mount still gets
# the documented limits.
COPY uploads.ini /usr/local/etc/php/conf.d/uploads.ini

# Sized from live FPM measurements of a 20-module site (opcache ~68 MB used for
# ~1,800 scripts, interned strings ~8 of 16 MB, JIT buffer under 1 MB, APCu a
# few dozen entries in 256 MB). The headroom left is still ~3x; the memory not
# reserved stays available to FPM workers inside the container limit.
# opcache.enable_cli=0: without opcache.file_cache every CLI process
# (omeka-s-cli, Omeka background jobs) compiles into a fresh private segment
# that dies with it, so CLI opcache only adds start-up cost. The trade-off is
# that long CPU-bound CLI jobs no longer get the JIT; Omeka jobs are dominated
# by database and image work, where it does not matter.
COPY <<EOF /usr/local/etc/php/conf.d/90-opcache.ini
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
; Extensions can change on persistent volumes through EasyAdmin or the CLI.
opcache.revalidate_freq=2
opcache.enable_cli=0
opcache.enable_file_override=1
opcache.validate_timestamps=1
opcache.jit=1255
opcache.jit_buffer_size=32M
EOF

COPY <<EOF /usr/local/etc/php/conf.d/91-realpath-cache.ini
realpath_cache_size=4096K
realpath_cache_ttl=600
EOF

COPY <<EOF /usr/local/etc/php/conf.d/docker-php-ext-apcu.ini
extension=apcu.so
apc.enabled=1
apc.shm_size=64M
apc.ttl=7200
EOF

# php.ini-production still announces the exact PHP version in an X-Powered-By
# header on every response; there is no reason to hand that to scanners.
COPY <<EOF /usr/local/etc/php/conf.d/93-hardening.ini
expose_php = Off
EOF

# ImageMagick resource limits. Debian's policy lets ONE conversion hold 1 GiB of
# heap plus a 2 GiB memory map, outside PHP's memory_limit (the Imagick
# thumbnailer runs inside the FPM worker). Five workers thumbnailing at once
# could then exceed the php container's ~1.5 GB limit and get it OOM-killed.
#
# memory=256MiB caps the heap pixel cache per conversion. A larger image spills
# its pixel cache to a file in /tmp — the only writable scratch space, a 256M
# tmpfs that is itself RAM shared by all workers and PHP's upload temp files.
# disk=256MiB keeps one conversion within what /tmp can hold, so an oversized
# image fails cleanly with "cache resources exhausted" instead of filling /tmp
# under concurrent uploads; map (memory-mapping that file) is subordinate to
# disk and is set to 512MiB only so it is never the tighter limit.
#
# Trade-off: the largest image that still gets thumbnails drops from roughly
# 1 GiB of pixel cache to 256 MiB — about 40 megapixels RGB / 32 megapixels
# RGBA at Q16 (e.g. a 7000x5000 scan; an A3 page scanned at 600 dpi does not
# fit). Omeka degrades gracefully: readImage() failing raises
# CannotCreateThumbnailException, the media is stored without thumbnails and
# can be re-thumbnailed later. Deployments that ingest larger scans should give
# ImageMagick a disk-backed temporary-path and a larger disk limit.
#
# Coder and delegate rules stay exactly as Debian ships them (PDF thumbnails go
# through Ghostscript). The edit is a targeted sed, and the build fails unless
# the effective limits Imagick itself reports are the intended ones, so a
# reformatted upstream policy cannot silently drop the cap.
RUN <<'IMAGEMAGICK'
set -euo pipefail
policy=/etc/ImageMagick-7/policy.xml
test -f "$policy"
sed -E -i \
    -e 's#(<policy domain="resource" name="memory" value=")[^"]*(")#\1256MiB\2#' \
    -e 's#(<policy domain="resource" name="map" value=")[^"]*(")#\1512MiB\2#' \
    -e 's#(<policy domain="resource" name="disk" value=")[^"]*(")#\1256MiB\2#' \
    "$policy"
php -r '
    $expected = [
        "memory" => [Imagick::RESOURCETYPE_MEMORY, 256 * 1024 ** 2],
        "map" => [Imagick::RESOURCETYPE_MAP, 512 * 1024 ** 2],
        "disk" => [Imagick::RESOURCETYPE_DISK, 256 * 1024 ** 2],
    ];
    foreach ($expected as $name => [$type, $bytes]) {
        $actual = Imagick::getResourceLimit($type);
        if ((int) $actual !== $bytes) {
            fwrite(STDERR, "ImageMagick $name limit is $actual, expected $bytes; policy edit did not apply.\n");
            exit(1);
        }
    }
'
IMAGEMAGICK
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
# targets in one Dockerfile, built from the one runtime code layer, guarantees
# core/module/theme assets change together while media remains a separately
# mounted read-only volume.
#
# nginx only needs the files it may serve itself. Its allow-list (nginx.conf)
# executes nothing but /index.php through FastCGI and 404s every other .php,
# application/ outside asset/, and modules/themes outside asset/ and
# theme.jpg. Shipping Omeka's PHP source and vendor/ into the web image would
# only add size and attack surface, so this stage assembles exactly:
#   index.php                 must exist so `index index.php` resolves "/"
#                             (nginx checks the file; PHP-FPM runs its own copy)
#   application/asset/
#   modules/*/asset/
#   themes/*/asset/, themes/*/theme.jpg
# plus empty files/, modules/ and themes/ mountpoints. In the base stack the
# module/theme volumes cover the image's copies; under compose.immutable.yml no
# volume is mounted there, so these trees ARE what nginx serves. Symlinks are
# dereferenced so a link into a path the web image does not carry still works.
# Root-owned and world-readable: nginx workers only ever read.
FROM runtime AS web-root
USER root
RUN <<'WEBROOT'
set -euo pipefail
src=/var/www/html
dst=/opt/web-root

copy_tree() {
    local rel="$1"
    mkdir -p "$dst/$(dirname "$rel")"
    cp -RL --preserve=mode,timestamps "$src/$rel" "$dst/$rel"
}

if [ ! -d "$src/application/asset" ] || [ -z "$(ls -A "$src/application/asset")" ]; then
    echo "ERROR: $src/application/asset is missing or empty; refusing to build a web image without core assets." >&2
    exit 1
fi
mkdir -p "$dst/files" "$dst/modules" "$dst/themes"
cp -L --preserve=mode,timestamps "$src/index.php" "$dst/index.php"
copy_tree application/asset

shopt -s nullglob
for path in "$src"/modules/*/asset "$src"/themes/*/asset "$src"/themes/*/theme.jpg; do
    [ -d "$path" ] || [ -f "$path" ] || continue
    copy_tree "${path#"$src"/}"
done

chown -R root:root "$dst"
chmod -R u=rwX,go=rX "$dst"
echo "web root: $(find "$dst" -type f | wc -l) files, $(du -sh "$dst" | cut -f1)"
WEBROOT

FROM nginx:1.30.7-alpine@sha256:caf4e1e032a20f9c3c5e28fc7f25ffd768ad8677b4975c54193075997b3a97e3 AS web

# Pick up Alpine security fixes published after the base image was built (the
# runtime stage does the same with apt-get upgrade).
RUN apk upgrade --no-cache

COPY --from=web-root --chown=0:0 /opt/web-root/ /var/www/html/
