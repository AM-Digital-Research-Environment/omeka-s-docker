# Building your own instance

How to decide what your site is built *with*: its modules, themes, vocabularies,
and any services or web server rules of your own. To add a module to a site that
is already running, use the admin panel instead (see the
[README](../README.md#modules-and-themes)).

## Pick where your changes live

This template is meant to be configured, not copied and rewritten. Before you
start, pick one of two ways to add your own modules and themes:

| | Edit the lists directly | Add a deployment folder |
|---|---|---|
| **Where you work** | `_docker/extra-modules.txt`, `_docker/extra-themes.txt` | `compose.<yourname>.yml` and `deploy/<yourname>/` |
| **Best if** | You run one site and this repository is yours | You run several sites, or you want to keep pulling updates from this template |
| **What it affects** | Every build from this copy of the repository | Only the sites that switch it on |
| **Example to copy** | — | [`deploy/amira/`](../deploy/amira/README.md) |

If you expect to pull future updates from this template, take the second option.
It adds files rather than changing existing ones, so updates merge cleanly. See
[Deployment overlays](#deployment-overlays), and
[institution setup](INSTITUTION_SETUP.md) for proxy trust, resource limits,
volume names, and fork settings.

## Modules

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
full GitHub references. Naming an exact version is worth the small effort: a
rebuild six months from now then installs the same code, not whatever the
module's authors have changed since. If a module needs extra libraries, the
build fetches them for you.

The scripts write these lines for you:

```bash
bash scripts/install-module.sh https://github.com/owner/repo/releases/download/v1.2.3/Module.zip
bash scripts/install-module.sh gh:owner/repository v1.2.3
```

Each command adds a line to the list, rebuilds, and restarts the site. You can
also edit the lists by hand and run `bash scripts/rebuild-code.sh` once at the
end.

These lists are what a site starts life with. Once it is running, the site owns
its modules and themes, so a new line in a list does not appear on a running
site by itself. `bash scripts/update-extensions.sh` applies pinned lines to the
running site and moves them to their newest release; the admin panel works too.
Keep the lists in step with what the site actually runs, so a fresh build
reproduces it.

Only add to `_docker/default-modules.txt` if a module genuinely belongs in
*every* site built from this template. For anything specific to your own
deployment, use your own list and point `EXTRA_MODULES_FILE` at it from your
deployment folder — `compose.amira.yml` shows how.

## Themes

Every image includes Omeka's `freedom` and `lively` themes. Add more the same
way as modules, in `_docker/extra-themes.txt` or with:

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

You need the second form only occasionally. The download tool names the folder
after the theme's display name, read from its `theme.ini`, but Omeka's database
remembers which theme a site uses by **folder name**. If a theme is called
something like `Africa Multiple — DRE`, the folder ends up as
`Africa_Multiple_____DRE`, and any site that expected `DRE-theme` quietly loses
its design. Naming the folder explicitly avoids that. `deploy/amira/themes.txt`
shows it in use.

## Code that isn't published anywhere

For a module or theme with no public repository — something written in-house, a
fork you haven't released, or a module inherited from an older site — put the
files straight into the build:

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

**Put your assets in `asset/`.** The rule lists what *is* public rather than what
isn't, so a module that later adds a new build tool or test folder can't
accidentally start exposing it. A theme whose stylesheets live anywhere else
will look unstyled. Data files work fine here too — a dashboard that loads JSON
from its own `asset/` folder is normal and supported.

**Only one PHP file can ever run.** Omeka routes every page through a single
entry script, so the web server refuses to run any other PHP file. Even if
something managed to write a malicious script into the site folder, it could not
be executed through the web.

Without these rules, a visitor could request a module's `composer.json` and read
a precise list of every library version the site runs — a shopping list for
matching against known vulnerabilities.

## Custom vocabularies

In addition to Omeka's built-in vocabularies (Dublin Core, Dublin Core Type,
Bibliographic Ontology, Friend of a Friend), these are imported on first run:

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
automatically — nothing else changes. A copy of the repository without those
lines runs the plain template.

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
[`deploy/amira/`](../deploy/amira/README.md)), which runs the live site at
[data.africamultiple.uni-bayreuth.de](https://data.africamultiple.uni-bayreuth.de).
It uses all four: it adds an [MCP server](https://modelcontextprotocol.io/) that
lets AI assistants search the collection at `/mcp`, installs the DRE modules and
theme, and imports the `dre` vocabulary. Its README walks through setting up your
own.

## Build and check

```bash
bash scripts/rebuild-code.sh    # builds and restarts; waits until the site is healthy
docker compose ps               # everything should say "healthy"
docker compose logs -f php      # watch the install, modules, and vocabularies load
```

Commit your module and theme lists and any local code. Do **not** commit `.env`
— it holds your passwords. With the lists committed, a colleague who clones your
repository builds exactly the same site you have.
