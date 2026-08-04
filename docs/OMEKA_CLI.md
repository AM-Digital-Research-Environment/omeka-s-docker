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
# List module code and database state
docker compose exec php omeka-s-cli module:list

# Turn on a module whose code is already there
docker compose exec php omeka-s-cli module:install CSVImport

# Apply a pending module database migration after deploying new code
docker compose exec php omeka-s-cli module:upgrade CSVImport

# Disable / enable / uninstall
docker compose exec php omeka-s-cli module:disable CSVImport
docker compose exec php omeka-s-cli module:enable CSVImport
docker compose exec php omeka-s-cli module:uninstall CSVImport

# Discover modules (searches the registries the CLI knows about)
docker compose exec php omeka-s-cli module:search facet
```

`module:download`, `module:update`, and `theme:download` work on a running site,
because modules and themes are stored outside the image. This is the same thing
the Easy Admin module does from the admin panel:

```bash
docker compose exec php omeka-s-cli module:download CSVImport
docker compose exec php omeka-s-cli module:install CSVImport
```

If the site uses `compose.immutable.yml`, those two downloads will not work —
the application folder is read-only while the site runs. Add the module to a
list and run `bash scripts/rebuild-code.sh` instead.

`module:upgrade` changes the database, so run it only after you have tested the
new code and taken a backup. Going back to older code restores the code but
does not undo a database migration.

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

# Core code upgrades are image builds, not live CLI writes
bash scripts/update-omeka.sh 4.2.1
```

### Vocabularies

The vocabulary files from `_docker/vocabularies/` are placed in
`/usr/local/share/omeka-vocabs/` during the build, and a deployment folder can
mount extra ones alongside them. They are imported automatically the first time
the site starts — the commands below are only needed to import one by hand.

```bash
docker compose exec php ls /usr/local/share/omeka-vocabs/
# fabio.owl  frapo.owl  geo.rdf  marcrel.rdf  vocabularies.json  ...
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

## Scripts or CLI?

The dividing line is simple: **scripts change Omeka itself, the CLI changes
everything else.**

| Task | Use | Why |
|---|---|---|
| Add or update a module or theme | **Easy Admin, or omeka-s-cli** | They are stored outside the image, so a running site can change them |
| Move to a new Omeka S version | `scripts/update-omeka.sh` | Omeka's own code is built in: backs up, pins the version, rebuilds |
| Turn a module on or off | **omeka-s-cli** | Database state |
| Apply a module or core database upgrade | **omeka-s-cli** | `module:upgrade`, `core:migrate` — deliberately manual |
| Users, vocabularies, resource templates, settings | **omeka-s-cli** | The scripts don't cover these |

On a site using `compose.immutable.yml`, the first row moves to
`scripts/install-module.sh` / `install-theme.sh`, the lists in `_docker/`, and
`scripts/update-module.sh` for anything tracking a branch. There, a download
command failing inside the container is the design working, not a permissions
problem to fix.

## Where to look when something breaks

- Run with `-v` or `-vv` for more verbose output: `omeka-s-cli module:update Cron -vv`
- `omeka-s-cli core:status` checks that the CLI can read the install (config, DB, files dir)
- Upstream issues and full command reference: <https://github.com/GhentCDH/Omeka-S-Cli>
