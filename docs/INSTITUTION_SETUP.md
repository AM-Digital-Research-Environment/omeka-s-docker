# Reusing this template at another institution

The base stack has no AMIRA hostname, branding, vocabulary or MCP dependency.
Keep institutional changes in `.env`, a deployment folder and a Compose overlay.
You can then adopt upstream fixes without editing the shared Dockerfile.

## Minimal deployment

Copy `.env.example` to `.env`, set a strong `MYSQL_PASSWORD`, and set your
`SERVER_NAME`. Keep the default loopback web binding when a host reverse proxy
terminates TLS. Start with `docker compose up -d --build`.

For a deliberately direct HTTP installation without a proxy:

```dotenv
NGINX_BIND=0.0.0.0
NGINX_TRUSTED_PROXY_CIDR=192.0.2.1/32
```

The documentation-only address disables trust in real clients' forwarded
headers. It is not a proxy to configure or connect to. Direct HTTP is suitable
for an isolated test installation; use TLS in front of a public deployment.

For a reverse proxy, set `NGINX_TRUSTED_PROXY_CIDR` to its address as seen by
the web container, usually the Docker bridge gateway for a host proxy. Inspect
the web container's network through Docker and narrow the default
`172.16.0.0/12` to that IP or an explicitly trusted subnet. Custom Docker bridges
using `10.x` or `192.168.x` need an explicit setting. Do not expose the container
port to untrusted clients who can connect from within the trusted range.
Both client-IP and HTTPS forwarding depend on this trust setting. Multiple
proxy networks can be supported by an institutional replacement for
`nginx-http-settings.conf`; keep real-IP and HTTPS trust rules consistent.

## Extensions and branding

Create `deploy/example/modules.txt` and `deploy/example/themes.txt` using the
manifest format documented in the README. Add an overlay:

```yaml
services:
  php:
    build:
      args:
        EXTRA_MODULES_FILE: deploy/example/modules.txt
        EXTRA_THEMES_FILE: deploy/example/themes.txt
  web:
    build:
      args:
        EXTRA_MODULES_FILE: deploy/example/modules.txt
        EXTRA_THEMES_FILE: deploy/example/themes.txt
```

Select it in `.env` on the Linux deployment host:

```dotenv
COMPOSE_FILE=docker-compose.yml:compose.example.yml
```

Both services must use identical build arguments. If extensions should be
immutable, put `compose.immutable.yml` immediately after the base file and
before your institutional overlay. Otherwise extensions remain admin-managed
on persistent volumes. Rebuilds alone do not update existing extension volumes.

`scripts/update-module.sh` checks only generic and selected deployment
manifests, including custom file paths. `scripts/update-extensions.sh` also
updates live extension volumes and runs pending migrations. These commands
require a valid `.env`/Compose configuration. Use `--dry-run` first. Keep
changes to files rather than scattering release URLs through shell history;
review pins before committing them.

## Resource limits

The `.env.example` settings expose web, PHP, database and search CPU/memory
limits while retaining conservative defaults. For example:

```dotenv
PHP_CONTAINER_MEMORY=3G
PHP_CPU_LIMIT=2.0
```

This is an example, not a recommended size for every collection. Measure with
`bash scripts/health-report.sh` during representative imports and thumbnail
jobs. It prints states, restart counts, OOM flags and container resource use,
but not environments or log contents. It returns nonzero if a container is
not running and healthy. Use the institution's existing monitoring to call it.

PHP's per-request limit remains in `uploads.ini`; the FPM pool size has separate
settings. Cache and tmpfs allocations also count against the container limit.
Database buffer-pool tuning is documented separately in `DB_TUNING.md`.
Keep memory/CPU limits at least as large as Compose's reservations, or adjust
reservations in your overlay as well.

## Storage, backup and recovery

Backup and restore resolve mounted named volumes from Compose, so an institution
can supply explicit names without relying on the checkout or project name:

```yaml
volumes:
  omeka_media:
    name: institution-collection-media
```

Use distinct names for independent installations. External volumes must already
exist and be provisioned with the intended driver. The supplied helpers target
local Docker named volumes; bind-mounted media/database storage is rejected
before data operations. Use a site-specific backup procedure for other storage
backends, rather than assuming these helpers capture them.

The default backup keeps the site running. Use a short maintenance window for
a matched SQL/media backup:

```bash
bash scripts/backup.sh --quiesce
```

This stops only running `web`/`php` services and starts those same services on
exit, including failures. Pause any external writers yourself. A forced process
kill or host failure can still require restarting the services manually.
Search indexes and optional precomputed dashboards are rebuilt from Omeka after
recovery. New backups do not copy Typesense's live database files.

See `BACKUP_RESTORE.md` for integrity verification and legacy archive handling.
Keep an encrypted off-host copy and test a restore into an independent project
before changing DNS. Retention, encryption keys and alert destinations belong
to the institution's own operations setup.

## GitHub forks

Dependabot does not assign an upstream operator to your PRs. Adapt schedules or
review ownership to your team. Generic validation and smoke tests remain active.
The AMIRA MCP release workflow runs in the upstream repository only; set the
repository Actions variable `ENABLE_AMIRA_RELEASE_CHECK=true` if your fork
actually uses that optional service and should receive its release issues.
