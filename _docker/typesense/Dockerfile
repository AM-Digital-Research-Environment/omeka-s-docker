# Typesense search backend (docker-compose.yml, profile "search").
#
# Upstream images are built on Ubuntu and are not rebuilt between Typesense
# releases, so OS security fixes (openssl, apt, ...) published after a release
# never reach them. This adds those fixes on top of the pinned release and
# changes nothing else: same binary, entrypoint and user (root, as upstream;
# compose drops all capabilities and mounts the root filesystem read-only).
#
# Pinned by digest. Dependabot watches this directory.
FROM typesense/typesense:30.2@sha256:610f2d34b1f93d00762869da2c67736775e5798d19a2c8b91b014b8a0cc1e110

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
