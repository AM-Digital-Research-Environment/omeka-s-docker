# Omeka S CLI

This Docker image ships with [`omeka-s-cli`](https://github.com/GhentCDH/Omeka-S-Cli) (GhentCDH), a command-line interface for managing an Omeka S installation without the web UI. It is installed at `/usr/local/bin/omeka-s-cli` in the `php` container (see [Dockerfile](../Dockerfile)).

For the full, authoritative command reference see the upstream repo: **<https://github.com/GhentCDH/Omeka-S-Cli>**. This doc covers the Docker-specific usage and the workflows you are most likely to hit.

## How to invoke

The CLI lives inside the `php` container. All commands are prefixed with `docker compose exec php`:

```bash
docker compose exec php omeka-s-cli <command> [args...]

# Examples
docker compose exec php omeka-s-cli module:list
docker compose exec php omeka-s-cli user:list
```

The container's `WORKDIR` is `/var/www/html`, so `--base-path` is usually not needed. If a command complains about not finding Omeka, add `--base-path /var/www/html`.

To explore commands and per-command flags:

```bash
docker compose exec php omeka-s-cli              # top-level command list
docker compose exec php omeka-s-cli module:update --help
```

## Common workflows

### Modules

```bash
# List installed modules (state, version, latest available, update flag)
docker compose exec php omeka-s-cli module:list

# Update one module to the latest released version
docker compose exec php omeka-s-cli module:update Cron

# Update all modules
docker compose exec php omeka-s-cli module:update --all

# Update and run any pending DB upgrade migrations in one go
docker compose exec php omeka-s-cli module:update Cron --upgrade

# Install a new module (download + activate)
docker compose exec php omeka-s-cli module:download CSVImport
docker compose exec php omeka-s-cli module:install CSVImport

# Disable / enable / uninstall
docker compose exec php omeka-s-cli module:disable CSVImport
docker compose exec php omeka-s-cli module:enable CSVImport
docker compose exec php omeka-s-cli module:uninstall CSVImport

# Discover modules (searches the registries the CLI knows about)
docker compose exec php omeka-s-cli module:search facet
```

`--upgrade` is the important one after a module update — some modules ship DB migrations that only run when the module's `upgrade` hook fires.

### Users

```bash
# List users
docker compose exec php omeka-s-cli user:list

# Create a new user (role: global_admin, site_admin, editor, reviewer, author, researcher)
docker compose exec php omeka-s-cli user:add user@example.org "Display Name" editor "TempPassword123"

# Reset a forgotten admin password (delete + re-add is the simplest path,
# or use SQL — the CLI does not currently expose a password-set command)
docker compose exec php omeka-s-cli user:disable user@example.org

# API keys (for headless integrations)
docker compose exec php omeka-s-cli user:create-api-key user@example.org
```

### Core

```bash
# Show installed Omeka S version
docker compose exec php omeka-s-cli core:version

# Run pending database migrations (after a core upgrade or restore from an
# older backup)
docker compose exec php omeka-s-cli core:migrate

# Upgrade the core (does NOT run DB migrations automatically — follow with
# core:migrate)
docker compose exec php omeka-s-cli core:update
```

### Vocabularies

The Dockerfile pre-stages a set of RDF vocabulary files under `/usr/local/share/omeka-vocabs/` (see [Dockerfile:135](../Dockerfile#L135)):

```bash
docker compose exec php ls /usr/local/share/omeka-vocabs/
# dre.owl  fabio.owl  frapo.owl  geo.rdf  marcrel.rdf  ...
```

To import one, supply the file plus the required `--label`, `--namespace-uri`, and `--prefix` flags:

```bash
docker compose exec php omeka-s-cli vocabulary:import \
    --file /usr/local/share/omeka-vocabs/frapo.owl \
    --label "FRAPO" \
    --namespace-uri "http://purl.org/cerif/frapo/" \
    --prefix frapo
```

Alternatively, a JSON config file (path or URL) can describe multiple imports — pass it via `--config`. See `omeka-s-cli vocabulary:import --help` for the full flag list, and `vocabulary:create-import-config` to scaffold one.

### Resource templates

Useful for moving resource templates between installations:

```bash
docker compose exec php omeka-s-cli resource-template:list
# Export to a file (the filename is an argument, not a redirect target)
docker compose exec php omeka-s-cli resource-template:export "Article" /tmp/article.json
docker compose cp php:/tmp/article.json ./article.json
# Import on another instance (after copying the JSON file in):
docker compose exec php omeka-s-cli resource-template:import /path/to/article.json
```

### Global settings

```bash
docker compose exec php omeka-s-cli config:list
docker compose exec php omeka-s-cli config:get installation_title
docker compose exec php omeka-s-cli config:set installation_title "My Archive"
```

## CLI vs. the `scripts/` bash helpers

This repo also ships `scripts/install-module.sh`, `scripts/update-module.sh`, etc. They overlap with the CLI but serve different needs:

| Task | Prefer | Why |
|---|---|---|
| Routine module install/update | **omeka-s-cli** | Knows upstream registries, handles enable/migrate lifecycle |
| Update one module to a *specific* tag or off-default branch | `scripts/update-module.sh <name> <tag>` | The bash scripts let you pin to an arbitrary git ref |
| Install a module that isn't in the CLI's known registries | `scripts/install-module.sh` | The bash scripts have an explicit repo map you can edit |
| Bulk operations that touch the DB (migrations) | **omeka-s-cli** | `module:update --upgrade` and `core:migrate` are CLI-native |
| Anything user / vocab / resource-template / settings related | **omeka-s-cli** | The bash scripts don't cover these |

In short: reach for the CLI first; fall back to the bash scripts when you need version pinning or are working with a module the CLI doesn't know about.

## Where to look when something breaks

- Run with `-v` or `-vv` for more verbose output: `omeka-s-cli module:update Cron -vv`
- `omeka-s-cli core:status` checks that the CLI can read the install (config, DB, files dir)
- Upstream issues and full command reference: <https://github.com/GhentCDH/Omeka-S-Cli>
