# Omeka S Docker Template

[![CI](https://github.com/AM-Digital-Research-Environment/omeka-s-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/AM-Digital-Research-Environment/omeka-s-docker/actions/workflows/ci.yml)

A ready-to-run Docker setup for hosting an Omeka S digital archive. Copy it,
choose your modules and themes, and you have a site that installs itself, is
hardened for public use, and can be rebuilt identically at any time.

Built for the [Africa Multiple](https://www.africamultiple.uni-bayreuth.de/)
research-data platform and kept general enough for anyone else to run their own
instance from it.

## Features

- **Installs itself**: Omeka S and its modules are set up during the build and
  configured the first time the site starts
- **One-command setup**: a [bootstrap script](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap)
  takes a blank Linux server to a working HTTPS site
- **Modules and themes included**: a useful set is ready to switch on, and you
  can add more from the browser — no terminal needed
- **Manageable from the admin panel**: installing, updating, and removing
  modules and themes works the way Omeka documents it, through the Easy Admin
  module (see [Modules and themes](#modules-and-themes))
- **Omeka itself can't change underneath you**: the core, its libraries, and its
  configuration are fixed at build time; updates are deliberate rebuilds, and
  rolling one back is easy. Sites that want the same guarantee for modules and
  themes can [switch it on](#locking-modules-and-themes-down)
- **Tuned for real use**: PHP 8.5 with caching and image processing, MySQL
  settings sized for an Omeka workload, browser caching and compression
- **Hardened by default**: the database is unreachable from outside, containers
  run without root or extra privileges, and only public files are served
- **Health-checked**: every service reports whether it is actually working, so a
  broken start is visible immediately
- **Extendable without forking**: your own services, modules, and vocabularies
  layer on top in a separate folder, so you can keep pulling updates from here
  (see [Deployment overlays](#deployment-overlays))

## Prerequisites

- A Linux server (or any machine) with Docker and Docker Compose v2
- Roughly 4 GB of RAM for a comfortable small-to-medium instance

## Project structure

```
.
├── .env.example                # Copy to .env — all your settings live there
├── docker-compose.yml          # The services: web, php, database, optional search
├── compose.immutable.yml       # Optional: lock modules and themes to the build
├── compose.amira.yml           # Example of adding your own services (see deploy/amira/)
├── Dockerfile                  # How the Omeka image is built
├── docker-entrypoint.sh        # Runs on startup: install Omeka, modules, vocabularies
├── _docker/                    # Everything that goes into the build
│   ├── default-modules.txt     # Modules every site built from this template gets
│   ├── extra-modules.txt       # Add your own modules here
│   ├── extra-themes.txt        # Add your own themes here
│   ├── local-modules/          # Unpublished modules: drop the folder in
│   ├── local-themes/           # Unpublished themes: drop the folder in
│   ├── local.config.php        # Omeka's own settings (thumbnails, storage, logging)
│   ├── vocabularies/           # Vocabularies imported when the site first starts
│   ├── empty-modules.txt       # Placeholder — leave alone
│   └── empty-themes.txt        # Placeholder — leave alone
├── deploy/
│   └── amira/                  # A complete worked example of a real deployment
├── nginx.conf                  # Web server: what is public, what is cached
├── nginx-http-settings.conf    # Compression, rate limiting, client IP handling
├── nginx-security-headers.conf # Security headers
├── uploads.ini                 # Upload size limits
├── docs/
│   ├── COMMANDS.md             # Everyday commands, in one place
│   ├── IMMUTABLE_CODE.md       # How code and data are stored; legacy migration
│   ├── OMEKA_CLI.md            # Managing users, vocabularies and settings from the shell
│   ├── PRODUCTION.md           # Going public: HTTPS, firewall, server hardening
│   ├── BACKUP_RESTORE.md       # Backups, restores, moving to another server
│   └── DB_TUNING.md            # What each database setting does
├── scripts/
│   ├── rebuild-code.sh         # Rebuild and restart on new Omeka / PHP / web server code
│   ├── install-module.sh       # Add a module to what a build starts with
│   ├── install-theme.sh        # Add a theme to what a build starts with
│   ├── update-module.sh        # Re-download modules that track a branch
│   ├── update-omeka.sh         # Move to a new Omeka S version
│   ├── backup.sh               # Back up database, files, and settings
│   └── restore.sh              # Restore a backup, here or on a new server
├── .github/                    # Automated checks that run on every change
├── backups/                    # Where backups land by default
└── sideload/                   # Drop files here for bulk import
```

## How this template works

Please read this before your first build. It is the one way this setup differs
from a normal Omeka S install, and it explains why Omeka and its modules are
updated in two quite different ways.

**Omeka itself is part of the image, not something you edit later.** Omeka's own
code, its libraries, and its configuration are installed when the image is
built. Once the site is running, none of it can be changed — not by you, and not
by anyone who breaks in. Moving to a new Omeka version is therefore a deliberate
rebuild:

> `bash scripts/update-omeka.sh` → the site restarts on the new code

**Modules and themes are the opposite: the running site owns them.** The lists
in `_docker/` fill the module and theme folders the first time a site starts.
After that those folders belong to the site, so you add, update, and remove
modules and themes from the admin panel exactly as the Omeka handbook describes
— no terminal, no rebuild, no downtime. A later image rebuild leaves them alone.

If you would rather nothing in the site's code folder ever be writable, you can
[turn that off](#locking-modules-and-themes-down) and go back to a rebuild for
every module and theme change.

**The web server and PHP are built together.** They are two halves of one image,
so the stylesheets nginx serves always match the PHP that produced the page
asking for them. This is why every helper script rebuilds both — never just one.

**These are the only things that can be written while the site runs:**

| What | Where it lives |
|------|----------------|
| Uploaded files and thumbnails | `omeka_media` volume |
| Modules | `omeka_modules` volume |
| Themes | `omeka_themes` volume |
| Omeka's log files | `omeka_logs` volume |
| Login sessions | `php_sessions` volume |
| The database password file | Regenerated in memory on every start |
| Your `local.config.php` | A file on the host, which the site can only read |
| Everything else, Omeka included | Part of the image — read-only |

Everything in that table lives outside the image, so a rebuild leaves your
database, files, modules, themes, and settings exactly as they were.

The payoff is that Omeka itself is reproducible: the same repository at the same
commit always builds the same Omeka, you can tell exactly what version is
running, and undoing a bad upgrade is just going back to the previous image.

For the full details, and for the one-time migration if your deployment predates
this layout, see [docs/IMMUTABLE_CODE.md](docs/IMMUTABLE_CODE.md).

## What runs

The site is made of a few small services that talk to each other:

| Service | What it is | Reachable from | Job |
|---------|-----------|----------------|-----|
| **web** | nginx 1.30.4 | The outside world (port 80) | Serves pages and files, hands page requests to `php` |
| **php** | PHP 8.5.9 | `web` only | Runs Omeka S |
| **db** | MySQL 9.7.2 | `php` only | Stores everything |
| **typesense** _(optional)_ | Typesense 30.2 | `php` only | Search index, if you use a search module |

Only `web` is reachable from outside, and even that binds to the machine itself
by default, expecting an HTTPS proxy in front (see
[Production SSL/TLS](#production-ssltls)). The database is never exposed.

Every version above is locked to an exact published image, so a rebuild can't
silently pick up a different one.

> **typesense** is entirely optional and off by default. See
> [Search backend](#search-backend-optional).
>
> Services specific to one deployment — the AMIRA MCP server, for example — are
> not part of this list. They live in a separate file (see
> [Deployment overlays](#deployment-overlays)).

## Quick start

### Option A: One command, on a fresh Linux server

On a blank Ubuntu, Debian, Fedora, Rocky, or Alma server, this installs Docker,
downloads the latest release of this template, offers to set up HTTPS with Caddy,
and starts the site:

```bash
curl -fsSL https://raw.githubusercontent.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap/main/setup.sh | bash
```

It asks a few questions and does the rest. See
[am-omeka-s-docker-bootstrap](https://github.com/AM-Digital-Research-Environment/am-omeka-s-docker-bootstrap)
for the details, or carry on below to do it by hand.

Running a script straight from the internet always deserves a moment's thought.
If you'd rather read it first, download it, look it over, then run it.

### Option B: By hand

#### 1. Get the files and set your password

```bash
git clone https://github.com/AM-Digital-Research-Environment/omeka-s-docker.git my-omeka-site
cd my-omeka-site

cp .env.example .env
nano .env          # set MYSQL_PASSWORD — that is the only required setting
```

#### 2. Start it

```bash
docker compose up -d --build

docker compose logs -f php    # watch it install; press Ctrl-C to stop watching
```

The first build takes several minutes: it downloads Omeka, all the modules, and
their supporting libraries. Later builds are much faster.

#### 3. Open it

```bash
docker compose ps      # wait until everything says "healthy"
```

Then visit `http://localhost` (or your server's address).

If you filled in `OMEKA_ADMIN_EMAIL`, `OMEKA_ADMIN_USERNAME`, and
`OMEKA_ADMIN_PASSWORD` in `.env`, your admin account already exists — just log
in. Otherwise Omeka's setup wizard will walk you through creating one.

#### 4. Add more modules (optional)

A useful set of modules is already installed (see
[Included modules](#included-modules)). To add another, log in as an admin and
use the **Easy Admin** module, which is installed and ready: it lists what is
available, installs it, and tells you when an update exists. No terminal, no
rebuild, no downtime.

The same thing from the command line, if you prefer:

```bash
docker compose exec php omeka-s-cli module:download CSVImport
docker compose exec php omeka-s-cli module:install CSVImport
```

Modules and themes you add this way are kept in their own storage, separate from
the built image, so they survive restarts, rebuilds, and Omeka upgrades — and
the backup script saves them with everything else. If you would rather fix them
to the build, see [Locking modules and themes
down](#locking-modules-and-themes-down).

[docs/OMEKA_CLI.md](docs/OMEKA_CLI.md) covers the rest of what you can do from
the command line: users, vocabularies, resource templates, and settings.

## Building your own instance

This template is meant to be configured, not copied and rewritten. Before you
start, pick one of two ways to add your own modules and themes:

| | Edit the lists directly | Add a deployment folder |
|---|---|---|
| **Where you work** | `_docker/extra-modules.txt`, `_docker/extra-themes.txt` | `compose.<yourname>.yml` and `deploy/<yourname>/` |
| **Best if** | You run one site and this repository is yours | You run several sites, or you want to keep pulling updates from this template |
| **What it affects** | Every build from this copy of the repository | Only the sites that switch it on |
| **Example to copy** | — | [`deploy/amira/`](deploy/amira/README.md) |

If you expect to pull future updates from this template, take the second option.
It adds files rather than changing existing ones, so updates merge cleanly. See
[Deployment overlays](#deployment-overlays) for how to set one up.

### 1. Settings

```bash
cp .env.example .env
```

`MYSQL_PASSWORD` is the only value you must set. If the site will be reachable
from the internet, also set `SERVER_NAME` and read
[docs/PRODUCTION.md](docs/PRODUCTION.md) first.

To change Omeka's own settings — thumbnail sizes, where files are stored, how
much gets logged — copy `_docker/local.config.php`, edit your copy, and point
`OMEKA_LOCAL_CONFIG` at it. The site can read that file but never writes to it,
and the backup script always saves whichever copy is actually in use.

### 2. Modules and themes

Add each one with its exact version — a published release archive if the project
offers one, otherwise a tag:

```bash
bash scripts/install-module.sh https://github.com/owner/repo/releases/download/v1.2.3/Module.zip
bash scripts/install-module.sh gh:owner/repository v1.2.3
bash scripts/install-theme.sh  gh:omeka-s-themes/CenterRow v1.8.0
```

Each command adds a line to the list, rebuilds, and restarts the site. You can
also edit the lists by hand and run `bash scripts/rebuild-code.sh` once at the
end.

These lists are what a site starts life with. Once it is running, modules and
themes are managed from the admin panel instead — see
[Modules and themes](#modules-and-themes). Keep the lists in step with what the
site actually runs, so a fresh build reproduces it.

Naming an exact version (a release tag or a commit) is worth the small effort:
it means a rebuild six months from now installs the same code, not whatever the
module's authors happen to have changed since.

If a module needs extra libraries, the build fetches them for you.

### 3. Code that isn't published anywhere

For a module or theme with no public repository — something written in-house, or
inherited from an older site — put its files in
`_docker/local-modules/<ModuleName>/` or `_docker/local-themes/<ThemeName>/`.
The build installs them for you. See
[Modules and themes of your own](#modules-and-themes-of-your-own).

### 4. One rule to know about

The web server only serves files from an `asset/` folder inside a module or
theme. Anything else in there is hidden, on purpose. If you write your own theme
and put its stylesheets somewhere else, the browser will not be able to load
them and the site will look unstyled. Most existing modules and themes already
follow this convention. See [What the site serves](#what-the-site-serves).

### 5. Extra vocabularies

Put the vocabulary file and a small `.json` description of it in
`_docker/vocabularies/`. They are imported the first time the site starts. See
[Custom vocabularies](#custom-vocabularies).

### 6. Build and check

```bash
bash scripts/rebuild-code.sh    # builds and restarts; waits until the site is healthy
docker compose ps               # everything should say "healthy"
docker compose logs -f php      # watch the install, modules, and vocabularies load
```

Commit your module and theme lists and any local code. Do **not** commit `.env`
— it holds your passwords. With the lists committed, a colleague who clones your
repository builds exactly the same site you have.

## Settings (the `.env` file)

Everything you can configure lives in one file. Copy `.env.example` to `.env` and
edit it. Settings marked **rebuild** become part of the image, so changing one
means running `bash scripts/rebuild-code.sh` rather than just restarting.

### Database

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `MYSQL_PASSWORD` | **Yes** | — | Password for Omeka's database user. Pick a long random one |
| `MYSQL_DATABASE` | No | `omeka` | Name of the database |
| `MYSQL_USER` | No | `omeka` | Database user Omeka connects as |

The database's own root password is generated randomly at first start and is
never needed for day-to-day work.

### The site

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `OMEKA_VERSION` | No | `4.2.1` | **rebuild** — which Omeka S release to install. `latest` picks up whatever is newest at build time, which by definition hasn't been tested with this template; you'll get a warning if you use it |
| `OMEKA_ADMIN_EMAIL` | No | — | Set all three admin settings and the first account is created for you, skipping the setup wizard. Set only some and they're ignored |
| `OMEKA_ADMIN_USERNAME` | No | — | Display name of that first account |
| `OMEKA_ADMIN_PASSWORD` | No | — | Its password. Consider removing it from `.env` once the site is up |
| `OMEKA_TZ` | No | `UTC` | Timezone, e.g. `Europe/Berlin` |
| `OMEKA_LOCALE` | No | — | Language, e.g. `en_US` |
| `OMEKA_TITLE` | No | — | Site title |
| `OMEKA_LOCAL_CONFIG` | No | `./_docker/local.config.php` | Path to your copy of Omeka's own configuration file |

### Being reachable

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `NGINX_PORT` | No | `80` | Which port on the machine the site answers on. Use `8080` if something else (an HTTPS proxy) holds port 80 |
| `NGINX_BIND` | No | `127.0.0.1` | Who can reach that port. The default means "this machine only", which is what you want behind an HTTPS proxy. Use `0.0.0.0` to serve plain HTTP directly to the internet |
| `SERVER_NAME` | No | `_` | Your public hostname, e.g. `omeka.example.edu`. The default accepts any name, which is fine only when a proxy sits in front |
| `FRAME_ANCESTORS` | No | `'self'` | Which other websites may embed your site in a frame. Default: only your own. Example: `"'self' https://www.example.org"` |

### Modules, themes, and extras

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `ENABLE_IIIF` | No | `false` | **rebuild** — installs IiifServer, ImageServer, and Mirador for IIIF image viewing |
| `EXTRA_MODULES` | No | — | **rebuild** — modules as a comma-separated list. The `_docker/extra-modules.txt` file is easier to review, so prefer that |
| `EXTRA_THEMES` | No | — | **rebuild** — same, for themes |
| `EXTRA_MODULES_FILE` | No | `_docker/empty-modules.txt` | **rebuild** — points at a second module list. This is how a deployment folder adds its own modules |
| `EXTRA_THEMES_FILE` | No | `_docker/empty-themes.txt` | **rebuild** — the same, for themes |
| `OMEKA_ASSET_REFRESH` | No | `stable` | **rebuild** — forces modules to be downloaded again. `rebuild-code.sh --refresh` sets it for you; you shouldn't need it by hand |

### Search (optional)

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `TYPESENSE_API_KEY` | No | — | Shared secret between the search engine and the search module. Required once search is switched on |
| `TYPESENSE_HOST` | No | `typesense` | Where the site finds the search engine |
| `TYPESENSE_PORT` | No | `8108` | Its port |
| `TYPESENSE_PROTOCOL` | No | `http` | Plain HTTP is correct here — the traffic never leaves the machine |

### Performance

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `PHP_PM_MAX_CHILDREN` | No | `5` | How many requests the site handles at once. Five fits the memory this container is given; raise both together if you have a bigger server |
| `PHP_PM_START_SERVERS` | No | `2` | How many workers start up immediately |
| `PHP_PM_MIN_SPARE_SERVERS` | No | `1` | Keep at least this many idle and ready |
| `PHP_PM_MAX_SPARE_SERVERS` | No | `3` | Shut down idle workers above this many |
| `PHP_PM_MAX_REQUESTS` | No | `500` | Restart a worker after this many requests, so slow memory leaks can't build up |

All five must be whole numbers greater than zero, or the site refuses to start.

### Adding your own deployment

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `COMPOSE_FILE` | No | — | Switches on a deployment folder, e.g. `docker-compose.yml:compose.amira.yml`. Once set, every `docker compose` command includes it automatically |
| `COMPOSE_PROFILES` | No | — | Switches on optional services, e.g. `search` |
| `AMIRA_MCP_VERSION` | No | see `compose.amira.yml` | AMIRA only: which release of the MCP server to run. Set it with `deploy/amira/update-amira-mcp.sh` |

## What's tuned out of the box

You should not need to change any of this, but it is worth knowing what you have.

### PHP
- 512 MB memory per request, 100 MB uploads, 5-minute limit on long operations
- Compiled-code and object caching switched on, so pages don't get re-parsed
- ImageMagick, Ghostscript, and PDF tools available for thumbnails and derivatives

### Database
- 512 MB kept in memory for frequently used data
- Up to 250 simultaneous connections
- See [docs/DB_TUNING.md](docs/DB_TUNING.md) if you need to change any of it

### Web server
- Compression for text, CSS, JavaScript, and JSON
- Images, fonts, and scripts cached in the browser for a year
- Security headers, including control over who may embed your site in a frame
- The admin login page is limited to 5 attempts per minute, slowing down
  password guessing
- Only public files are served — see [What the site serves](#what-the-site-serves)

## What the site serves

Omeka keeps all of its own code inside the same folder the web server reads
from. That means the web server, not Omeka, decides what the public can see, and
this template keeps that list short. If you write your own module or theme,
these are the rules to work within:

| Someone requests | They get |
|------------------|----------|
| The site itself — pages, admin, search | The page, as normal |
| `asset/` inside a module or theme | The file (stylesheets, scripts, images, data) |
| `theme.jpg` in a theme | The file — Omeka's theme picker needs it |
| Anything else inside a module or theme | Nothing (404) |
| Omeka's own source folders: `config`, `data`, `logs`, `vendor`, `application` | Nothing (404) |
| `composer.json`, `package-lock.json`, `README.md`, `.env`, and similar | Nothing (404) |
| Any `.ini`, `.yml`, `.sql`, `.sh`, `.log`, or backup file | Nothing (404) |
| A `.php` file other than the site's own front page script | Nothing (404) |

Two things follow from this that are worth knowing:

**Put your assets in `asset/`.** The rule lists what *is* public rather than what
isn't, so a module that later adds a new build tool or test folder can't
accidentally start exposing it. Data files work fine here too — a dashboard that
loads JSON from its own `asset/` folder is normal and supported.

**Only one PHP file can ever run.** Omeka routes every page through a single
entry script, so the web server refuses to run any other PHP file. Even if
something managed to write a malicious script into the site folder, it could not
be executed through the web.

Why this matters: without these rules, a visitor could simply request a module's
`composer.json` and read a precise list of every library version the site runs —
a shopping list for matching against known vulnerabilities.

Deployment folders can add their own rules without editing `nginx.conf` — see
[Deployment overlays](#deployment-overlays).

## Everyday operations

### Viewing logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f php
docker compose logs -f web
docker compose logs -f db
```

### Restarting services

```bash
# Single service
docker compose restart php

# All services
docker compose down && docker compose up -d
```

### Opening a shell inside a container

```bash
# PHP container
docker compose exec php bash

# MySQL
docker compose exec db mysql -u omeka -p
```

### Update Omeka S itself

```bash
# See what would change, without changing anything
bash scripts/update-omeka.sh --dry-run

# Move to the newest release
bash scripts/update-omeka.sh

# Move to a specific release
bash scripts/update-omeka.sh 4.2.1
```

The script backs up first, records the new version in `.env`, and rebuilds. If
the build fails it puts your old `.env` back and leaves the running site alone.
Omeka's own database upgrade stays a separate, deliberate step — you confirm it
in the admin interface once you're happy with the new code.

### Update modules and themes

From the admin panel, through the Easy Admin module — it flags what has an
update and applies it. Or from the command line:

```bash
docker compose exec php omeka-s-cli module:list          # what's installed, what's outdated
docker compose exec php omeka-s-cli module:update Cron   # fetch the newer code
docker compose exec php omeka-s-cli module:upgrade Cron  # then apply its database changes
```

`module:upgrade` changes the database, so back up first — going back to older
code does not undo it.

The two commands below apply only to sites that have
[locked modules and themes down](#locking-modules-and-themes-down); on a normal
site they rebuild the image without changing what is running:

```bash
bash scripts/rebuild-code.sh    # after editing a version in _docker/extra-modules.txt
bash scripts/update-module.sh   # re-download anything tracking a branch
```

## Modules

### Modules and themes

Modules and themes work the way the Omeka S handbook describes: you manage them
from the admin panel, using the **Easy Admin** module that ships with this
template. It lists what is available, installs and removes it, and flags
updates. Nothing about that requires a terminal.

They are stored separately from the built image, which has two consequences
worth knowing:

- What you install stays installed. Restarting, rebuilding the image, or
  upgrading Omeka does not remove it, and `scripts/backup.sh` includes it.
- Rebuilding the image no longer changes them. The modules and themes listed in
  `_docker/` are used to set the site up the first time it starts; after that
  the site's own copies are what counts. To change them later, use the admin
  panel rather than a rebuild — the rebuild script reminds you of this when it
  runs.

Omeka itself is different: the core, its libraries, and its configuration are
fixed in the image and cannot be written to at runtime. Upgrading Omeka is
always a deliberate rebuild ([Update Omeka S itself](#update-omeka-s-itself)).

#### Locking modules and themes down

Sites run by someone comfortable at a terminal can extend that same guarantee
to modules and themes, so that nothing in the site's code folder can ever be
written to — even by Omeka itself. Add one line to `.env` and restart:

```bash
# In .env — directly after docker-compose.yml, before any other compose file
COMPOSE_FILE=docker-compose.yml:compose.immutable.yml
```

```bash
docker compose up -d
```

Easy Admin then reports that the module and theme folders are not writeable,
which is expected: the image becomes the only source of both, and you add them
with `scripts/install-module.sh` and `scripts/install-theme.sh` as described
under [Building your own instance](#building-your-own-instance).

Before switching, add anything you installed from the admin panel to
`_docker/extra-modules.txt` and `_docker/extra-themes.txt` (or your deployment
folder's lists) and run `bash scripts/rebuild-code.sh` — otherwise it disappears
from the running site. Your storage is left alone, so removing the line again
brings back exactly what was there.

> **The order of the files matters.** Docker Compose cannot remove a single
> setting when it merges files, so `compose.immutable.yml` replaces the whole
> storage list for the web and PHP services. Put it directly after
> `docker-compose.yml` and before your own deployment file, or that file's
> settings are thrown away:
> `COMPOSE_FILE=docker-compose.yml:compose.immutable.yml:compose.amira.yml`.
> CI checks both that the right order works and that the wrong one is rejected.

### Included modules

These come with every site built from this template. They are listed in
`_docker/default-modules.txt`, installed during the build, and registered the
first time the site starts — you just switch them on in the admin interface.

| Module | What it's for |
|--------|---------------|
| **ActivityLog** | Keeps a record of who changed what |
| **Common** | Shared code that several of the modules below need |
| **Cron** | Runs scheduled background jobs |
| **CustomVocab** | Define your own controlled vocabularies |
| **EasyAdmin** | Extra admin tools and maintenance tasks |
| **FileSideload** | Import files placed on the server, instead of uploading one by one |
| **Hierarchy** | Arrange items and item sets in a tree |
| **ItemCarouselBlock** | A carousel of items for site pages |
| **Log** | Writes module and job messages to a readable log |
| **NumericDataTypes** | Proper number and date fields, so ranges and sorting work |

**Switch them on in this order**, because some depend on others:

1. Common and Log
2. Cron
3. EasyAdmin, then everything else

### Adding your own

This is how you decide what a site is built *with*. To add something to a site
that is already running, use the admin panel instead —
[Modules and themes](#modules-and-themes).

Put one module per line in `_docker/extra-modules.txt`. A release archive URL is
the best line to write, because it installs the module exactly as its authors
packaged it — no development tree, no git history:

```
https://github.com/owner/repository/releases/download/v1.2.3/Module.zip
```

Where a project publishes no releases, name a fixed version after the `#`
instead; that clones the repository at that point:

```
gh:owner/repository#v1.2.3
```

Plain names work too for modules in Omeka's own registry (`CSVImport`), as do
full GitHub references. `bash scripts/install-module.sh` writes these lines for
you and rebuilds in one step, and `bash scripts/update-module.sh` moves every
pinned release archive to that project's newest release before rebuilding.

Only add to `_docker/default-modules.txt` if a module genuinely belongs in
*every* site built from this template. For anything specific to your own
deployment, use your own list and point `EXTRA_MODULES_FILE` at it from your
deployment folder — `compose.amira.yml` shows how.

## Themes

Every image includes Omeka's `freedom` and `lively` themes. On a running site,
add more from the admin panel. To decide what a *new* build starts with, add
them the same way as modules:

```bash
bash scripts/install-theme.sh gh:omeka-s-themes/CenterRow v1.8.0
```

### When a theme needs a specific folder name

A line in `_docker/extra-themes.txt` can name the folder the theme should be
installed into:

```bash
gh:owner/SomeTheme#v2.0.0                  # usual case: nothing extra needed
gh:owner/SomeTheme#v2.0.0 my-theme-folder  # install it under this folder name
https://github.com/owner/SomeTheme/releases/download/v2.0.0/SomeTheme.zip my-theme-folder
```

The folder name is read from the theme's own `theme.ini` either way, so a
release archive needs the second field just as often as a `gh:` line does.

You need the second form only occasionally. The download tool names the folder
after the theme's display name, but Omeka's database remembers which theme a site
uses by **folder name**. If a theme is called something like
`Africa Multiple — DRE`, the folder ends up as `Africa_Multiple_____DRE`, and any
site that expected `DRE-theme` quietly loses its design. Naming the folder
explicitly avoids that, without having to copy the theme into this repository.
`deploy/amira/themes.txt` shows it in use.

If a theme looks unstyled after a build, check
[What the site serves](#what-the-site-serves) first.

## Modules and themes of your own

For code that isn't published anywhere — something written in-house, a fork you
haven't released, or a module inherited from an older site — put the files
straight into the build:

```
_docker/local-modules/MyModule/     becomes  modules/MyModule
_docker/local-themes/my-theme/      becomes  themes/my-theme
```

The folder name is the module or theme name; nothing else needs registering.
These are copied in *after* the downloads, and they fully replace a downloaded
module or theme of the same name — so no leftover files from the older version
can survive underneath. What you commit is exactly what runs.

Prefer a pinned version in `_docker/extra-modules.txt` where one exists — vendored
code here stops receiving updates, so keep it for the cases that genuinely need
it: private modules, or a fix that has not been released upstream yet.

## Custom vocabularies

In addition to the built-in vocabularies (Dublin Core, Dublin Core Type, Bibliographic Ontology, Friend of a Friend), the following RDF vocabularies are automatically imported on first run:

| Vocabulary | Prefix | Description |
|-----------|--------|-------------|
| **FRAPO** | `frapo` | Funding, Research Administration and Projects Ontology |
| **FaBiO** | `fabio` | FRBR-aligned Bibliographic Ontology |
| **WGS84 Geo** | `geo` | Latitude, longitude, altitude positioning |
| **MARC Relators** | `marcrel` | Library of Congress agent role terms |

The vocabulary files live in `_docker/vocabularies/`, next to a `vocabularies.json`
file that says, for each one, its prefix, its namespace URI, a label, and the
filename. The importer reads any `.json` file it finds in that folder, so you can
add your own two ways:

- **For every site built from this template**: put the vocabulary file in
  `_docker/vocabularies/`, add an entry to `vocabularies.json`, and rebuild.
- **For just your site**: keep the pair in your own deployment folder and mount
  them in — `deploy/amira/vocabularies/` does exactly this with its `dre`
  vocabulary, and is the shortest thing to copy.

Either way they are imported the first time the site starts. Vocabularies already
imported are left alone on later starts.

## IIIF support (optional)

IIIF is the standard that lets other institutions display and cite your images —
deep zoom, side-by-side comparison, shared annotations. Three modules provide
it: IiifServer, ImageServer, and Mirador.

**Setting up a new site**: switch them on before the first build, and they are
there from the start.

```bash
# In .env
ENABLE_IIIF=true
```

**On a site that is already running**, this setting no longer has any effect —
the module folder belongs to the site by then. Install the three from the admin
panel, or:

```bash
for m in IiifServer ImageServer Mirador; do
  docker compose exec php omeka-s-cli module:download "$m"
done
```

Set `ENABLE_IIIF=true` anyway, so a rebuild from scratch matches the site you
are running.

Then switch them on in the admin interface **in this order**, since each depends
on the one before:

1. Common (already installed)
2. IiifServer
3. ImageServer
4. Mirador

## Search backend (optional)

For faster, richer search than Omeka's built-in one, the template can run
[Typesense](https://typesense.org/) alongside the site, driven by a search module
such as [DRESearch](https://github.com/AM-Digital-Research-Environment/DRESearch)
(written for AMIRA, but usable anywhere).

**It is off by default and entirely optional.** Nothing about the rest of the
template depends on it, and leaving it off costs you nothing.

### Turning it on

1. Put a long random key in `.env`. The same key is used by both the search
   engine and the module:
   ```bash
   # generate one with:  openssl rand -hex 24
   TYPESENSE_API_KEY=your-long-random-string
   ```
2. Start the stack with search included:
   ```bash
   docker compose --profile search up -d
   ```
3. Install the search module. It picks up the connection settings automatically,
   so you can leave its admin configuration blank:
   ```bash
   docker compose exec php omeka-s-cli module:download https://github.com/AM-Digital-Research-Environment/DRESearch/releases/download/v1.19.1/DRESearch.zip
   docker compose exec php omeka-s-cli module:install DRESearch
   ```
   Check the project's
   [releases](https://github.com/AM-Digital-Research-Environment/DRESearch/releases)
   for the current version. On a site that has [locked modules and themes
   down](#locking-modules-and-themes-down), pass the same URL to
   `bash scripts/install-module.sh` instead.

To make this permanent, add `COMPOSE_PROFILES=search` to `.env` — then a plain
`docker compose up -d` includes it. To turn search off again, remove that line
and start normally.

### Why this doesn't make you less safe

- **Not reachable from outside.** The search engine opens no port to the
  internet or even to the server itself. Only the site can talk to it.
- **A key is required.** Starting it without `TYPESENSE_API_KEY` makes it exit
  immediately rather than run unprotected. The key only ever lives in `.env`,
  which is never committed.
- **Locked down like everything else**: no special privileges, a read-only
  filesystem, browser access disabled, and capped at half a CPU and 512 MB so it
  can't crowd out the site.
- **Nothing irreplaceable.** The index can always be rebuilt from the database.
  Backups include it anyway, purely to make recovery faster.

## Deployment overlays

`docker-compose.yml` stays deliberately generic. Anything specific to one
deployment — extra services, your own modules, custom vocabularies, extra web
server rules — goes in a **separate file that layers on top** (an *overlay*),
switched on from `.env`:

```bash
# In .env
COMPOSE_FILE=docker-compose.yml:compose.amira.yml
COMPOSE_PROFILES=search
```

Once those lines are there, every `docker compose` command picks the overlay up
automatically — nothing else changes, and all the commands in this README still
work. A copy of the repository without those lines runs the plain template.

The point is that **you never edit the shared files**, so you can keep pulling
updates from this template without merge conflicts. Four things can be added
this way:

| You want to add | How |
|-----------------|-----|
| Another service | Define it in your `compose.<name>.yml` |
| Extra web server rules (a new URL path) | Mount a `.conf.template` file into `/etc/nginx/templates/extra-locations/` |
| Your own modules or themes | Point `EXTRA_MODULES_FILE` / `EXTRA_THEMES_FILE` at your own list |
| Custom vocabularies | Mount the vocabulary file and its `.json` description into `/usr/local/share/omeka-vocabs/` |

**The example to copy** is the AMIRA deployment (`compose.amira.yml` plus
[`deploy/amira/`](deploy/amira/README.md)), which runs the live site at
[data.africamultiple.uni-bayreuth.de](https://data.africamultiple.uni-bayreuth.de).
It uses all four: it adds an [MCP server](https://modelcontextprotocol.io/) that
lets AI assistants search the collection at `/mcp`, installs the DRE modules and
theme, and imports the `dre` vocabulary. Its README walks through setting up your
own.

## Bulk imports

To import many files at once without uploading them one by one through the
browser:

1. Copy the files into the `sideload/` folder of this repository
2. Switch on the FileSideload module in the admin interface (it is already
   installed)
3. Go to **Modules > FileSideload > Configure** and set the sideload directory to
   `/var/www/html/sideload`
4. Import them from the admin interface as normal

## Troubleshooting

### I added a module to a list but it never appeared

The lists in `_docker/` fill the module and theme folders only the *first* time a
site starts. On a site that is already running, adding a line and rebuilding
changes nothing — `rebuild-code.sh` tells you so when it runs. Install it from
the admin panel instead, or from the command line:

```bash
docker compose exec php omeka-s-cli module:download CSVImport
docker compose exec php omeka-s-cli module:install CSVImport
```

The lists still matter: they are what a fresh build starts from, so keep them in
step with what your site actually runs.

On a site using `compose.immutable.yml` it works the other way round — there the
lists are the only source of modules and themes, and a rebuild is exactly how
you apply an edit.

### My theme or module looks unstyled

Its stylesheets are probably not in an `asset/` folder. See
[What the site serves](#what-the-site-serves).

### A service won't start

```bash
docker compose ps                  # which one is unhealthy?
docker compose logs php            # and why
```

The `php` service can take up to two minutes on a first start — it is installing
Omeka, its modules, and the vocabularies. Watch the log rather than the status.

### "Existing Omeka database detected, but the media volume carries no layout marker"

The database says a site is installed, but the mounted media volume is empty or
is not the one holding that site's files. Starting anyway would serve a site
whose media had silently vanished, so the container refuses.

Usually the media volume was renamed, removed, or never mounted — check that
`omeka_media` appears in `docker compose config` and still holds your files. If
the data really is gone, restore it:

```bash
bash scripts/restore.sh <backup-directory>
```

See [docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md).

### The search service exits immediately

It says `API key is not specified`. Set `TYPESENSE_API_KEY` in `.env` and start
again. This is deliberate: it refuses to run unprotected.

### Database connection problems

```bash
docker compose exec db mysql -u omeka -p -e "SELECT 1"
```

If that works but the site doesn't, check that `MYSQL_USER`, `MYSQL_DATABASE`,
and `MYSQL_PASSWORD` in `.env` match what the database was first created with.
Changing them later does not rename an existing database or user.

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

## Security

### What is already done for you

| | |
|---|---|
| **The database is unreachable** | It has no port open to the machine or the internet — only the site can talk to it |
| **The site itself listens locally by default** | It expects an HTTPS proxy in front. See [Production SSL/TLS](#production-ssltls) |
| **Nothing runs as root** | Omeka runs as an unprivileged user, and containers can't gain new privileges |
| **Omeka's own code can't be modified** | Omeka, its libraries, and its configuration are read-only while running. The module and theme folders are writable, because the admin panel manages them — [lock those down too](#locking-modules-and-themes-down) if you'd rather they weren't |
| **Only one PHP file can execute** | See [What the site serves](#what-the-site-serves) |
| **Private files aren't served** | Configuration, logs, source code, and dependency lists all return 404 |
| **Resource limits** | Each service has a CPU and memory cap, so one misbehaving part can't take the machine down |
| **Login is rate-limited** | 5 attempts per minute on the admin login page |
| **Versions are locked** | Every image is pinned to an exact published build, so a rebuild can't silently pull something different |

### What is left to you

**Keep your passwords out of Git.** `.env` holds them and is already ignored by
Git. Backups contain a copy of it, so encrypt backups before moving them
anywhere.

**Put HTTPS in front of the site.** The container speaks plain HTTP by design;
something on the host should terminate TLS. See
[Production SSL/TLS](#production-ssltls) and
[docs/PRODUCTION.md](docs/PRODUCTION.md).

**Anyone who can use Docker on the host is effectively root.** Treat access to
the server the same way you treat the admin password.

**Remove the admin password from `.env`** once the first account exists — it is
only needed for the very first start.

**Keep things updated:**

```bash
docker compose pull               # newer database / search images
bash scripts/rebuild-code.sh --pull   # newer PHP and web server base images
```

**Consider scanning your images** for known vulnerabilities, e.g.
`docker scout cves omeka-s-docker-php:latest`, and shipping logs somewhere you
actually read them.

**One trade-off to be aware of**: the database is configured to favour speed over
absolute durability, which means an abrupt power loss could lose about one second
of the very latest changes. If that matters for your content, see
`innodb-flush-log-at-trx-commit` in [docs/DB_TUNING.md](docs/DB_TUNING.md).

## Production SSL/TLS

The site itself speaks plain HTTP. For a public site, put something in front of
it that handles HTTPS certificates — Caddy is the least work, and the
[one-command setup script](#option-a-one-command-on-a-fresh-linux-server) sets it
up for you.

Whichever you choose, Omeka will produce correct `https://` links, emails, and
IIIF manifests automatically, as long as the proxy forwards the usual
`X-Forwarded-Proto` header (Caddy, Traefik, and standard nginx all do). No Omeka
configuration is needed. Set `SERVER_NAME` in `.env` to your public hostname.

### Caddy (easiest — certificates handled for you)

Install [Caddy](https://caddyserver.com/) on the server and create a Caddyfile:

```
omeka.example.edu {
    reverse_proxy 127.0.0.1:8080
}
```

Then set `NGINX_PORT=8080` in `.env` so Caddy can take port 80, apply it with
`docker compose up -d --force-recreate web`, and start Caddy. Certificates are
obtained and renewed automatically from then on.

### Traefik (Docker-native)

Add labels to the `web` service in a `docker-compose.override.yml`:

```yaml
services:
  web:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.omeka.rule=Host(`omeka.example.edu`)"
      - "traefik.http.routers.omeka.tls.certresolver=letsencrypt"
```

### Standalone nginx reverse proxy

First free port 80 on the host so the host nginx can bind it — set `NGINX_PORT=8080` in `.env` and run `docker compose up -d --force-recreate web`. The container nginx will then listen only on `127.0.0.1:8080`.

Install nginx on the host and create a site config:

```nginx
# HTTP → HTTPS redirect (also serves ACME HTTP-01 challenges)
server {
    listen 80;
    listen [::]:80;
    server_name omeka.example.edu;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS — terminates TLS and proxies to the Omeka container on :8080
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name omeka.example.edu;

    ssl_certificate     /etc/letsencrypt/live/omeka.example.edu/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/omeka.example.edu/privkey.pem;

    # Modern TLS (Mozilla intermediate)
    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache       shared:SSL:50m;
    ssl_session_timeout     1d;
    ssl_session_tickets     off;

    # Enable HSTS only after the cert pipeline is confirmed working
    # add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    # Match the container's upload limit (Omeka allows 100 MB)
    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
```

For a full production walk-through (firewall rules, cert provisioning paths, host-OS hardening, verification), see [docs/PRODUCTION.md](docs/PRODUCTION.md).

## Where your data lives

Everything that survives a rebuild is stored outside the image:

| Storage | What's in it | Backed up? |
|---------|--------------|------------|
| `mysql_data` | The database — items, users, settings, everything | Yes |
| `omeka_media` | Uploaded files and the thumbnails made from them | Yes |
| `omeka_logs` | Omeka's log files | Yes |
| `omeka_modules` | Modules, set up from the image and managed from the admin panel | Yes |
| `omeka_themes` | Themes, set up from the image and managed from the admin panel | Yes |
| `php_sessions` | Who is currently logged in. Kept on disk so a restart doesn't log everyone out | No — nothing worth keeping |
| `typesense_data` | The search index, if you use search | Yes, though it can always be rebuilt |

Your `.env` and your copy of `local.config.php` are ordinary files in this
repository folder, and the backup script copies them too.

## Backups and moving servers

```bash
# Back up everything
bash scripts/backup.sh

# Restore — on this server or a new one
bash scripts/restore.sh backups/20260330-120000
```

**The site stays up during a backup.** The database is captured as a single
consistent snapshot without blocking anyone, and files are read without being
locked. The one thing to avoid is installing or upgrading a module while a backup
runs, because that changes the database's structure mid-snapshot.

Each backup records checksums of everything it contains, so you can tell if a
copy was corrupted in transit. Those checksums are not encryption: a backup
contains your `.env`, so **encrypt it before storing it anywhere else**.

[docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md) covers restores, moving to
another server, and a suggested retention schedule.

If your deployment predates the current storage layout, run the one-time
migration described in [docs/IMMUTABLE_CODE.md](docs/IMMUTABLE_CODE.md).

## Getting help

- **Everyday commands**: [docs/COMMANDS.md](docs/COMMANDS.md)
- **Going public**: [docs/PRODUCTION.md](docs/PRODUCTION.md)
- **Backups and moving servers**: [docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md)
- **Managing users, vocabularies, settings**: [docs/OMEKA_CLI.md](docs/OMEKA_CLI.md)
- **A full real-world example**: [deploy/amira/README.md](deploy/amira/README.md)
- **Omeka S itself**: <https://omeka.org/s/docs/user-manual/>

## License

MIT — see [LICENSE](LICENSE).
