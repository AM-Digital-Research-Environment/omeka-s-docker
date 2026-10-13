# Omeka S Docker Template

[![CI](https://github.com/AM-Digital-Research-Environment/omeka-s-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/AM-Digital-Research-Environment/omeka-s-docker/actions/workflows/ci.yml)

A ready-to-run Docker setup for hosting an Omeka S digital archive. It installs
itself, is hardened for public use, and can be rebuilt identically at any time.

Built for the [Africa Multiple](https://www.africamultiple.uni-bayreuth.de/)
research-data platform and kept general enough for anyone else to run their own
instance from it.

- **Installs itself**: Omeka S and a useful set of modules are set up on the
  first start, admin account included if you want
- **Managed from the browser**: install, update, and remove modules and themes
  from the admin panel with the bundled Easy Admin module — no terminal needed
- **Omeka itself can't change underneath you**: the core is fixed in the image,
  so upgrades are deliberate and rolling one back is easy
- **Hardened and tuned by default**: nothing runs as root, the database is never
  exposed, only public files are served, and PHP, MySQL, and nginx come sized
  for an Omeka workload
- **Backups and restores in one command**, including moving to a new server
- **Extendable without forking**: your own modules, services, and vocabularies
  layer on top in a separate folder

## Quick start

You need a Linux server (or any machine) with Docker and Docker Compose v2, and
roughly 4 GB of RAM for a comfortable small-to-medium site.

### Option A: One command, on a fresh Linux server

On a blank Ubuntu, Debian, Fedora, Rocky, or Alma server, this installs Docker,
downloads the latest release of this template, offers to set up HTTPS with Caddy,
and starts the site:

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
```

It asks a few questions and prints your site's address and admin login at the
end. See [am-omeka-s-docker-bootstrap](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap)
for the options. Running a script straight from the internet deserves a moment's
thought: if you'd rather read it first, download it, look it over, then run it.

### Option B: By hand

```bash
git clone https://github.com/AM-Digital-Research-Environment/omeka-s-docker.git my-omeka-site
cd my-omeka-site

cp .env.example .env
nano .env          # set MYSQL_PASSWORD — the only required setting

docker compose up -d --build
docker compose logs -f php    # watch it install; Ctrl-C stops watching
```

The first build takes several minutes. When `docker compose ps` shows everything
as "healthy", visit `http://localhost` (or your server's address).

If you set `OMEKA_ADMIN_EMAIL`, `OMEKA_ADMIN_USERNAME`, and
`OMEKA_ADMIN_PASSWORD` in `.env`, your admin account already exists — just log
in. Otherwise Omeka's setup wizard walks you through creating one.

For a public site, put HTTPS in front of it next: see
[Going public](#going-public).

## How this template works

It differs from a normal Omeka S install in one way, and that decides how things
are updated:

**Omeka itself is part of the image.** Omeka's code, its libraries, and its
configuration are installed when the image is built, and nothing can change them
while the site runs — not you, and not anyone who breaks in. Moving to a new
Omeka version is a deliberate rebuild with `bash scripts/update-omeka.sh`, and
undoing a bad upgrade is just going back to the previous image.

**Modules and themes belong to the running site.** The lists in `_docker/` fill
the module and theme folders the first time a site starts. After that you add,
update, and remove them from the admin panel exactly as the Omeka handbook
describes — no terminal, no rebuild, no downtime. If you'd rather nothing in the
code folder were ever writable, you can
[lock modules and themes down](docs/IMMUTABLE_CODE.md#locking-modules-and-themes-down).

**Your data lives outside the image**, so a rebuild or upgrade leaves it alone:

| Storage | What's in it | Backed up? |
|---------|--------------|------------|
| `mysql_data` | The database — items, users, settings, everything | Yes |
| `omeka_media` | Uploaded files and their thumbnails | Yes |
| `omeka_modules`, `omeka_themes` | Modules and themes | Yes |
| `omeka_logs` | Omeka's log files | Yes |
| `php_sessions` | Who is logged in, so a restart doesn't log everyone out | No |
| `typesense_data` | The optional search index | No — rebuilt from Omeka |

Your `.env` and your copy of `local.config.php` are ordinary files in this
folder, and the backup script copies them too.

The site runs as a few small services: **web** (nginx 1.30), **php** (PHP 8.5,
running Omeka), **db** (MySQL 9.7), and optionally **typesense** for search.
Only `web` is reachable, and by default only from the machine itself, expecting
an HTTPS proxy in front. More detail in
[docs/IMMUTABLE_CODE.md](docs/IMMUTABLE_CODE.md).

## Modules and themes

These modules come with every site. Switch them on in the admin interface under
**Modules**:

| Module | What it's for |
|--------|---------------|
| **ActivityLog** | Keeps a record of who changed what |
| **Common** | Shared code that several of the modules below need |
| **Cron** | Runs scheduled background jobs |
| **CustomVocab** | Define your own controlled vocabularies |
| **EasyAdmin** | Install and update modules and themes; extra admin tools |
| **FileSideload** | Import files placed on the server, instead of uploading one by one |
| **Hierarchy** | Arrange items and item sets in a tree |
| **ItemCarouselBlock** | A carousel of items for site pages |
| **Log** | Writes module and job messages to a readable log |
| **NumericDataTypes** | Proper number and date fields, so ranges and sorting work |

**Switch them on in this order**, because some depend on others: Common and Log,
then Cron, then EasyAdmin, then everything else.

Omeka's `freedom` and `lively` themes are included too.

**To add more**, use Easy Admin: it lists what is available, installs it, and
tells you when an update exists. Or from the command line:

```bash
docker compose exec php omeka-s-cli module:download CSVImport
docker compose exec php omeka-s-cli module:install CSVImport
```

What you add stays installed through restarts, rebuilds, and Omeka upgrades,
and the backup script saves it. To decide what a *fresh* build starts with —
module lists, pinned versions, in-house code, custom vocabularies — see
[docs/CUSTOMISING.md](docs/CUSTOMISING.md).

## Keeping it up to date

**Modules and themes**: from Easy Admin, which flags updates. Or from the command
line:

```bash
docker compose exec php omeka-s-cli module:update Cron   # fetch the newer code
docker compose exec php omeka-s-cli module:upgrade Cron  # then apply its database changes
```

`module:upgrade` changes the database, so back up first. To update everything in
the module and theme lists at once:

```bash
bash scripts/update-extensions.sh --dry-run   # see what would change
bash scripts/update-extensions.sh             # back up, update, apply database changes
```

This updates the running site in place: no rebuild, no restart.

**Omeka S itself**:

```bash
bash scripts/update-omeka.sh --dry-run   # see what would change
bash scripts/update-omeka.sh             # newest release, or name one: 4.2.1
```

The script backs up first, records the new version in `.env`, and rebuilds. If
the build fails it puts your old `.env` back and leaves the running site alone.
You then confirm Omeka's database upgrade in the admin interface.

**PHP, nginx, MySQL**:

```bash
docker compose pull                    # newer database and search images
bash scripts/rebuild-code.sh --pull    # newer PHP and web server images
```

## Backups

```bash
bash scripts/backup.sh                 # back up everything to backups/<date>/
bash scripts/backup.sh --keep 7        # ...and keep only the 7 newest
bash scripts/restore.sh backups/20260330-120000   # restore, here or on a new server
```

The site stays up during a backup. Every backup is a **full** copy, so give
`--keep` a number in your scheduled backup rather than deleting old directories
by hand. A backup contains your `.env` and its passwords, so **encrypt it before
storing it anywhere else**. [docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md)
covers restores, moving servers, and a retention schedule.

## Optional extras

**IIIF image viewing** (IiifServer, ImageServer, Mirador). On a new site, set
`ENABLE_IIIF=true` in `.env` before the first build. On a running site, install
the three from Easy Admin, or:

```bash
for m in IiifServer ImageServer Mirador; do
  docker compose exec php omeka-s-cli module:download "$m"
done
```

Set `ENABLE_IIIF=true` anyway, so a rebuild from scratch matches. Switch them on
in this order: Common, IiifServer, ImageServer, Mirador.

**Faster search** with [Typesense](https://typesense.org/), driven by a search
module such as [DRESearch](https://github.com/AM-Digital-Research-Environment/DRESearch)
(written for AMIRA, usable anywhere). Off by default; nothing else depends on it.

1. Put a long random key in `.env`, e.g. from `openssl rand -hex 24`:
   `TYPESENSE_API_KEY=...`
2. Add `COMPOSE_PROFILES=search` to `.env` and run `docker compose up -d`.
3. Install the module from its
   [latest release](https://github.com/AM-Digital-Research-Environment/DRESearch/releases)
   with `omeka-s-cli module:download <release-zip-url>` and `module:install
   DRESearch`. It picks up the connection settings automatically.

**Bulk file imports**: copy the files into `sideload/`, switch on FileSideload,
set its directory to `/var/www/html/sideload` under **Modules > FileSideload >
Configure**, and import from the admin interface as normal.

Every setting is listed in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Going public

The site speaks plain HTTP and, by default, answers only on the machine itself.
For a public site, put an HTTPS proxy in front — Caddy is the least work, and the
one-command setup script configures it for you. By hand, with Caddy installed:

```
omeka.example.edu {
    reverse_proxy 127.0.0.1:8080
}
```

Then set `NGINX_PORT=8080` and `SERVER_NAME=omeka.example.edu` in `.env`, run
`docker compose up -d --force-recreate web`, and start Caddy.
[docs/PRODUCTION.md](docs/PRODUCTION.md) covers Traefik and host nginx, the
firewall, certificates, and what the template already hardens for you.

Three things are left to you: keep `.env` out of Git (it already is ignored),
remove `OMEKA_ADMIN_PASSWORD` from `.env` once the first account exists, and
treat access to Docker on the server as root access.

## Troubleshooting

### A service won't start

```bash
docker compose ps                  # which one is unhealthy?
docker compose logs php            # and why
```

The `php` service can take up to two minutes on a first start while it installs
Omeka, its modules, and the vocabularies. Watch the log rather than the status.

### I added a module to a list but it never appeared

The lists in `_docker/` fill the module folder only the *first* time a site
starts. On a running site, install it from Easy Admin or with `omeka-s-cli`
(see [Modules and themes](#modules-and-themes)), or run
`bash scripts/update-extensions.sh` to apply pinned lines. On a site using
`compose.immutable.yml` it works the other way round: there the lists are the
only source, and a rebuild is how you apply an edit.

### My theme or module looks unstyled

Its stylesheets are probably not in an `asset/` folder, the only part of a module
or theme the web server serves. See
[What the site serves](docs/CUSTOMISING.md#what-the-site-serves).

### The search service exits immediately

It says `API key is not specified`. Set `TYPESENSE_API_KEY` in `.env` and start
again. It refuses to run unprotected, on purpose.

### Database connection problems

```bash
docker compose exec db mysql -u omeka -p -e "SELECT 1"
```

If that works but the site doesn't, check that `MYSQL_USER`, `MYSQL_DATABASE`,
and `MYSQL_PASSWORD` in `.env` match what the database was first created with.
Changing them later does not rename an existing database or user.

### "Existing Omeka database detected, but the media volume carries no layout marker"

The database says a site is installed, but the media storage is empty or is not
the one holding that site's files, so the container refuses to serve a site
whose media had silently vanished. Check that `omeka_media` appears in
`docker compose config` and still holds your files. If the data really is gone,
restore it with `bash scripts/restore.sh <backup-directory>`.

### File permission problems

```bash
docker compose exec php id
docker compose exec php ls -ld /var/www/html/files
docker compose exec php chmod -R u=rwX,go=rX /var/www/html/files
```

New installations get this right by themselves. If an older set of files has the
wrong owner, back it up and fix the ownership during a maintenance window — the
running container is deliberately not allowed to change file ownership.

### Clearing caches

```bash
docker compose up -d --force-recreate php web
```

## Documentation

| Guide | What's in it |
|-------|--------------|
| [COMMANDS.md](docs/COMMANDS.md) | Everyday commands: logs, restarts, shells, rebuilds |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Every `.env` setting, and what's tuned out of the box |
| [CUSTOMISING.md](docs/CUSTOMISING.md) | Module and theme lists, in-house code, vocabularies, deployment overlays |
| [PRODUCTION.md](docs/PRODUCTION.md) | HTTPS, firewall, certificates, server hardening |
| [BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md) | Backups, restores, moving to another server |
| [OMEKA_CLI.md](docs/OMEKA_CLI.md) | Users, vocabularies, and settings from the command line |
| [IMMUTABLE_CODE.md](docs/IMMUTABLE_CODE.md) | How code and data are stored; locking modules and themes down |
| [INSTITUTION_SETUP.md](docs/INSTITUTION_SETUP.md) | Running this template at another institution |
| [DB_TUNING.md](docs/DB_TUNING.md) | What each database setting does |
| [deploy/amira/](deploy/amira/README.md) | A complete real-world deployment to copy |

For Omeka S itself, see the [Omeka S user manual](https://omeka.org/s/docs/user-manual/).

## License

MIT — see [LICENSE](LICENSE).
