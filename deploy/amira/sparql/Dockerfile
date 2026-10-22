# Read-only SPARQL endpoint over the DRE-LinkedData dump (compose.amira.yml,
# profile "sparql"). Oxigraph's own image is distroless — no shell, so no way
# to run the load-and-swap loop in sparql-entrypoint.sh — so this copies its
# binary onto Debian slim, which has the same glibc lineage, and adds socat to
# expose the server on a Unix socket: the container runs without any network,
# and nginx reaches it through the socket on a shared volume.
#
# Both images are pinned by digest. Dependabot watches this directory.
FROM ghcr.io/oxigraph/oxigraph:0.5.11@sha256:7532c1f9aa5f28c0dc6a4243198f7f6144017fab7429bf6c164a89fec9411767 AS oxigraph

FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

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
