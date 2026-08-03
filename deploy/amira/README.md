# AMIRA deployment overlay

This directory holds everything specific to the DRE production deployment at
[data.africamultiple.uni-bayreuth.de](https://data.africamultiple.uni-bayreuth.de) — the
[Africa Multiple](https://www.africamultiple.uni-bayreuth.de/) research-data platform (AMIRA).
The base stack in the repository root stays a generic, reusable Omeka S template; the overlay
adds the AMIRA pieces on top without forking anything.

It also doubles as the worked example of how to extend the template with your own
deployment-specific services — copy the pattern, not the content.

## What the overlay adds

| Piece | File | Mechanism |
|-------|------|-----------|
| `amira-mcp` service | [`compose.amira.yml`](../../compose.amira.yml) | Extra compose service on the `backend` network |
| `/mcp` nginx location | [`nginx-mcp-location.conf`](nginx-mcp-location.conf) | Mounted into `/etc/nginx/templates/extra-locations/`, rendered and glob-included by the base `nginx.conf` |
| DRE modules (DRESearch, DRE-SEO, ResourceVisualizations) | [`modules.txt`](modules.txt) | Baked into the php image via the `EXTRA_MODULES_FILE` build arg |
| `dre` custom vocabulary | [`vocabularies/`](vocabularies/) | `dre.owl` + `dre.json` manifest bind-mounted into the image's vocab dir; imported on first run |
| Typesense search | base `docker-compose.yml` | Enabled via `COMPOSE_PROFILES=search` (backend for the DRESearch module) |
| iframe embedding | `.env` | `FRAME_ANCESTORS` allows the frederickmadore.com domains |
| MCP release pin | `.env` | `AMIRA_MCP_VERSION` selects a published upstream tag; unset takes the default pinned in [`compose.amira.yml`](../../compose.amira.yml) |

## Activating the overlay

One-time edit of the server's `.env`:

```bash
COMPOSE_FILE=docker-compose.yml:compose.amira.yml
COMPOSE_PROFILES=search
FRAME_ANCESTORS="'self' https://www.frederickmadore.com https://slides.frederickmadore.com"
TYPESENSE_API_KEY=<long random string>
SERVER_NAME=data.africamultiple.uni-bayreuth.de
```

`AMIRA_MCP_VERSION` is deliberately absent: leaving it unset takes the release
pinned in [`compose.amira.yml`](../../compose.amira.yml), and
[`update-amira-mcp.sh`](update-amira-mcp.sh) writes it into `.env` when you move
to a newer release.

Docker Compose reads `COMPOSE_FILE` and `COMPOSE_PROFILES` from `.env`, so every
`docker compose` command (`up`, `logs`, `ps`, the backup scripts, …) automatically includes
the overlay — no `-f` flags needed. Plain `docker compose up -d` runs the full AMIRA stack;
a checkout without these `.env` lines runs the generic template.

After changing `.env`, apply with:

```bash
docker compose up -d --build
```

## MCP server (AMIRA)

The overlay runs the [amira-mcp-server](https://github.com/AM-Digital-Research-Environment/amira-mcp-server),
exposing this instance's public, read-only dataset to AI assistants over the
[Model Context Protocol](https://modelcontextprotocol.io/) (Streamable-HTTP/SSE) at:

```
https://data.africamultiple.uni-bayreuth.de/mcp
```

Point any MCP client (Claude, etc.) at that URL as a Streamable-HTTP server to get
search/list/get tools over the collection. The server bundles a snapshot of the public
Omeka S API and refreshes it periodically (`AMIRA_LIVE_REFRESH=true`), so it adds no load
to the live database.

### How requests are routed

`/mcp` must bypass Omeka's front controller, or Omeka would appropriate the URL
(404/redirect). The `web` nginx handles this with a dedicated, higher-precedence location
(`location ^~ /mcp` in [`nginx-mcp-location.conf`](nginx-mcp-location.conf)) that proxies to
the `amira-mcp` container with SSE buffering disabled. A host-level TLS reverse proxy in
front of the stack forwards `/mcp` through unchanged; for true un-buffered streaming and
per-client rate-limiting at that layer, see the optional tweaks in
[`MCP_HOST_NGINX.md`](MCP_HOST_NGINX.md).

### Keeping it up to date

The service builds from a published upstream release tag. Preview or deploy the
latest stable release with:

```bash
bash deploy/amira/update-amira-mcp.sh latest --dry-run
bash deploy/amira/update-amira-mcp.sh latest
```

The helper validates the published tag, records it in `.env`, builds it, and
recreates only `amira-mcp`. Use `--refresh-data` for a same-version rebuild of
the bundled data snapshot. The rest of the stack keeps running.

### Security

Like Typesense, the MCP server is built not to widen the attack surface:

- **Never exposed to the host or internet directly.** It publishes **no ports** — reachable
  only on the internal `backend` Docker network, and from the outside solely through the
  hardened `web` nginx at `/mcp`.
- **Read-only and public by design.** The underlying data is the same public collection
  already served by the site, so the endpoint needs no credentials. Abuse is bounded by an
  optional per-client rate limit at the host nginx (real client IPs are visible there,
  unlike behind Docker's bridge).
- **Hardened like the rest of the stack:** `cap_drop: ALL`, `no-new-privileges`, a read-only
  root filesystem (cache on tmpfs), and tight CPU/memory limits (0.25 CPU / 256M) so it
  can't starve the host.
- **Nothing secret to back up.** The bundled snapshot is rebuildable from the public API, so
  the service holds no persistent state.
- **web never depends on it.** The `/mcp` location resolves the upstream at request time via
  Docker's embedded DNS, so a missing or crashed `amira-mcp` container yields a 502 on
  `/mcp` only — never a site outage.

## Rolling your own overlay

To adapt this pattern for another deployment:

1. Create `deploy/<name>/` with your service configs, module list, and vocabularies.
2. Write a `compose.<name>.yml` at the repo root that adds your services and mounts:
   - extra nginx locations → `/etc/nginx/templates/extra-locations/*.conf.template`
   - extra baked modules → `build.args.EXTRA_MODULES_FILE: deploy/<name>/modules.txt`
   - extra vocabularies → bind-mount `<vocab>.owl` + `<vocab>.json` (manifest) into
     `/usr/local/share/omeka-vocabs/`
3. Activate with `COMPOSE_FILE=docker-compose.yml:compose.<name>.yml` in `.env`.

The base stack never needs editing, so you keep pulling template updates cleanly.
