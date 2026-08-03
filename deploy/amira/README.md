# AMIRA deployment overlay

This directory holds everything specific to the DRE production deployment at
[data.africamultiple.uni-bayreuth.de](https://data.africamultiple.uni-bayreuth.de) — the
[Africa Multiple](https://www.africamultiple.uni-bayreuth.de/) research-data platform (AMIRA).
The base stack in the repository root stays a generic, reusable Omeka S template; the overlay
adds the AMIRA pieces on top without forking anything.

It also doubles as the worked example of how to extend the template with your own
deployment-specific services — copy the pattern, not the content.

## What the overlay adds

| Piece | Defined in | How it attaches |
|-------|-----------|-----------------|
| `amira-mcp` service | [`compose.amira.yml`](../../compose.amira.yml) | An extra service on its own private `mcp` network, shared only with `web` |
| `/mcp` web address | [`nginx-mcp-location.conf`](nginx-mcp-location.conf) | Mounted into `/etc/nginx/templates/extra-locations/`, which the base `nginx.conf` includes automatically |
| DRE modules | [`modules.txt`](modules.txt) | Installed into the image via the `EXTRA_MODULES_FILE` setting |
| DRE-theme | [`themes.txt`](themes.txt) | Installed via `EXTRA_THEMES_FILE`, renamed to the folder the site rows expect |
| `dre` vocabulary | [`vocabularies/`](vocabularies/) | `dre.owl` + `dre.json` mounted into the vocabulary folder; imported on first start |
| Search | base `docker-compose.yml` | Switched on with `COMPOSE_PROFILES=search`, used by the DRESearch module |
| Storage for precomputed visualizations | [`compose.amira.yml`](../../compose.amira.yml) | A `dre_visualizations_data` volume — see [below](#the-visualizations-volume) |
| iframe embedding | `.env` | `FRAME_ANCESTORS` permits the frederickmadore.com domains |
| MCP version | `.env` | `AMIRA_MCP_VERSION`; leave unset to use the release pinned in [`compose.amira.yml`](../../compose.amira.yml) |

The modules installed for AMIRA are DRESearch, DRE-SEO, ResourceVisualizations
(which provides the `DreVisualizations` module), BulkEdit, Reference,
LocalContexts, and IframeEmbed. [`modules.txt`](modules.txt) is the authoritative
list and explains why each one is pinned the way it is.

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

After changing `.env`, apply it:

```bash
bash scripts/rebuild-code.sh
```

Use this rather than `docker compose up -d --build` — it rebuilds the PHP and web
images together (the automated checks reject them being out of step) and waits
until both report healthy before returning.

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

Like the search engine, the MCP server is set up so that adding it doesn't make
the site easier to attack:

- **Never exposed directly.** It opens **no ports** — it sits on a private `mcp`
  network shared only with the web server, and the outside world reaches it solely through
  the hardened `web` nginx at `/mcp`. It cannot reach the database or the search index at
  all.
- **Read-only and public by design.** The underlying data is the same public collection
  already served by the site, so the endpoint needs no credentials. Abuse is bounded by an
  optional per-client rate limit at the host nginx (real client IPs are visible there,
  unlike behind Docker's bridge).
- **Locked down like everything else:** no special privileges, a read-only filesystem, and a
  cap of a quarter CPU and 256 MB so it can't crowd out the site.
- **Nothing to back up.** Its copy of the data is rebuilt from the public API, so it keeps
  no state of its own.
- **The site never waits on it.** The `/mcp` rule looks the server up at the moment a request
  arrives, so if `amira-mcp` is stopped, crashed, or still building, only `/mcp` returns an
  error — the rest of the site is unaffected.

## The visualizations volume

The DreVisualizations module precomputes its dashboards, knowledge graph, and
photo galleries, and writes the results inside its own module folder. Because
module code is read-only here, the overlay mounts a writable volume,
`dre_visualizations_data`, over just that one sub-folder — for both `php` (which
writes it) and `web` (which serves it to browsers, read-only).

Two things to know:

**It is not backed up, on purpose.** Everything in it can be regenerated from the
database with the admin "Regenerate" action. Disaster recovery is: restore the
database and media, start the stack, regenerate.

**It hides the module's own shipped data files.** Docker copies them in the first
time the empty volume is mounted, and never again. So if a new release of
DreVisualizations changes those shipped inputs, a rebuild alone won't pick them
up — delete the volume and regenerate:

```bash
docker compose down
docker volume rm omeka-dre-dev_dre_visualizations_data
docker compose up -d
```

The real fix belongs upstream: the module should write under Omeka's `files/`
folder rather than into its own code. Until it does, this mount keeps it working
without patching the module.

## Rolling your own overlay

To adapt this pattern for another deployment:

1. Create `deploy/<name>/` and put your own module list, theme list, service
   configuration, and vocabularies in it.
2. Write a `compose.<name>.yml` in the repository root that adds your services
   and connects your files:
   - extra web addresses → mount a `.conf.template` into
     `/etc/nginx/templates/extra-locations/`
   - your modules → `build.args.EXTRA_MODULES_FILE: deploy/<name>/modules.txt`
   - your themes → `build.args.EXTRA_THEMES_FILE: deploy/<name>/themes.txt`
   - your vocabularies → mount the `.owl` and `.json` pair into
     `/usr/local/share/omeka-vocabs/`
3. Switch it on with `COMPOSE_FILE=docker-compose.yml:compose.<name>.yml` in
   `.env`.

Two things worth copying from this example:

- Set the same `EXTRA_MODULES_FILE` and `EXTRA_THEMES_FILE` on **both** the `php`
  and `web` services. They share one code layer, and the automated checks will
  fail the build if the two disagree.
- If your extra service needs to be reachable through the site, give it its own
  private network shared only with `web`, as `compose.amira.yml` does with `mcp`.
  It then has no route to the database.

Because you never edit the shared files, you can keep pulling updates from this
template without merge conflicts.
