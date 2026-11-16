# Typesense search backend (docker-compose.yml, profile "search").
#
# Upstream images are built on Ubuntu and are not rebuilt between Typesense
# releases, so OS security fixes (openssl, apt, ...) published after a release
# never reach them. This adds those fixes on top of the pinned release, and
# runs the server as an unprivileged user instead of upstream's root. Binary
# and entrypoint are unchanged.
#
# Volumes created by the upstream image are root-owned; hand them over once:
#   docker compose run --rm --no-deps --user 0 --cap-add CHOWN \
#     --entrypoint chown typesense -R 10002:10002 /data
#
# Pinned by digest. Dependabot watches this directory.
FROM typesense/typesense:30.2@sha256:610f2d34b1f93d00762869da2c67736775e5798d19a2c8b91b014b8a0cc1e110

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    # Fixed uid/gid so the volume handover above is the same everywhere. /data
    # is created owned by it, which seeds a fresh typesense_data volume.
    && groupadd --system --gid 10002 typesense \
    && useradd --system --uid 10002 --gid typesense --home-dir /nonexistent --shell /usr/sbin/nologin typesense \
    && install -d -o typesense -g typesense -m 0750 /data

USER typesense
