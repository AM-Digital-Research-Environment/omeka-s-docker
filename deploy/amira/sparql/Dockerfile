# Read-only SPARQL endpoint over the DRE-LinkedData dump (compose.amira.yml,
# profile "sparql"). Oxigraph's own image is distroless — no shell, so no way
# to run the load-and-swap loop in sparql-entrypoint.sh — so this copies its
# binary onto Debian slim, which has the same glibc lineage, and adds socat to
# expose the server on a Unix socket: the container runs without any network,
# and nginx reaches it through the socket on a shared volume.
#
# Both images are pinned by digest. Dependabot watches this directory.
FROM ghcr.io/oxigraph/oxigraph:0.5.12@sha256:10677fb643f8c5a7bfb03dd8f7971c79a84b01e795c24201c8cfa12fd569f1c0 AS oxigraph

FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4

RUN apt-get update \
    && apt-get install -y --no-install-recommends socat \
    && rm -rf /var/lib/apt/lists/* \
    # A fixed uid/gid: the sparql_socket tmpfs volume in compose.amira.yml is
    # mounted owned by 10001:10001.
    && groupadd --system --gid 10001 sparql \
    && useradd --system --uid 10001 --gid sparql --home-dir /nonexistent --shell /usr/sbin/nologin sparql \
    # Owned by the service user so a fresh sparql_data volume is seeded with
    # that ownership. /run/sparql is a tmpfs volume that sets its own owner.
    && install -d -o sparql -g sparql -m 0755 /data /run/sparql

COPY --from=oxigraph /usr/local/bin/oxigraph /usr/local/bin/oxigraph
COPY --chmod=0755 sparql-entrypoint.sh /usr/local/bin/sparql-entrypoint

USER sparql
ENTRYPOINT ["/usr/local/bin/sparql-entrypoint"]
