# How code and data are stored

This explains the storage model the template uses: what lives in the image, what
lives on a volume, and why.

## The model

**The image is the source of truth for Omeka itself.** Omeka's own code, its
libraries, and its configuration are installed when the image is built, and
nothing can change them on a running site. Upgrading Omeka is always a rebuild.

**Modules and themes are set up from the image, then owned by the site.** The
lists in `_docker/` are used to fill the module and theme storage the first time
a site starts. After that the site's own copies are what counts, so the admin
panel can install, update, and remove them the way Omeka documents — and a later
image rebuild does not overwrite what the site is running.

**PHP and the web server are built together.** They are two targets in the same
`Dockerfile`, and the web target copies the finished application folder out of
the PHP one. They therefore always ship exactly the same Omeka code, and they
share the same module and theme storage — a stylesheet the browser loads can
never come from a different version than the page that asked for it. This is why
the helper scripts always rebuild both.

**Everything else is writable only where it genuinely needs to be:**

| Path | Where it lives | Who can write it |
|---|---|---|
| `/var/www/html/files` | `omeka_media` volume | PHP; the web server reads it read-only |
| `/var/www/html/logs` | `omeka_logs` volume | PHP |
| `/var/www/html/modules` | `omeka_modules` volume | PHP; the web server reads it read-only |
| `/var/www/html/themes` | `omeka_themes` volume | PHP; the web server reads it read-only |
| `/var/lib/php-sessions` | `php_sessions` volume | PHP |
| `/var/www/html/config/database.ini` | Memory only, rewritten on every start, mode `0600` | The startup script |
| `/var/www/html/config/local.config.php` | A file on the host | Nobody — mounted read-only |
| `/tmp` and a few small working directories | Memory only | PHP |
| Everything else under `/var/www/html` | The image | Nobody |

The PHP container's filesystem is read-only apart from those paths.

**A marker file guards against a subtle failure.** `files/.immutable-layout-v1`
records that the media volume really is this site's own. If Omeka's database
says the site is installed but that marker is missing, the container refuses to
start rather than quietly serve a site whose media has vanished.

## What this buys you

- Omeka's own code cannot be modified on a running site, and the web server will
  not execute anything outside the places it is meant to.
- A rebuild from the same commit produces the same Omeka, at the same version.
- Undoing a bad Omeka upgrade is going back to the previous image.
- Meanwhile the parts a site administrator legitimately needs to change —
  modules and themes — stay changeable from the admin panel, without a terminal.

Because modules and themes can be written to, a break-in that gains control of
PHP could leave code behind in those two folders. That is true of any normal
Omeka installation, and it is the trade this template makes so the admin panel
works as documented. Sites that would rather not make it can lock those folders
down too — see below.

## Locking modules and themes down

Adding `compose.immutable.yml` to `COMPOSE_FILE` removes the module and theme
storage, so the image becomes the only source of both and nothing under the
application folder can be written to at all:

```bash
# In .env — directly after docker-compose.yml, before any deployment file
COMPOSE_FILE=docker-compose.yml:compose.immutable.yml
```

The admin panel then reports that the folders are not writeable, and modules and
themes are added the same way Omeka itself is updated:

```bash
# Add something new, at a fixed version — a release archive where there is one
bash scripts/install-module.sh https://github.com/owner/repo/releases/download/v1.2.3/Module.zip
bash scripts/install-module.sh gh:owner/repository v1.2.3
bash scripts/install-theme.sh gh:owner/theme 0123456789abcdef

# Apply your own edits to the module or theme lists
bash scripts/rebuild-code.sh

# Move pinned release archives to the newest release, and re-download anything
# tracking a branch rather than a fixed version
bash scripts/update-module.sh
```

Anything installed from the admin panel before the switch disappears from the
running site unless it is in those lists first. The storage itself is left
alone, so removing the line again brings it all back.

That file must come directly after `docker-compose.yml`: Docker Compose cannot
remove one setting during a merge, so it replaces the whole storage list for the
web and PHP services, and a deployment file listed before it would lose its own
settings. CI checks the supported order and rejects the other.

## Updating Omeka

```bash
bash scripts/update-omeka.sh 4.2.1
```

**A rollback restores code, not the database.** If a new version of Omeka or of a
module has already applied its database migration, going back to the old image
will not undo it. So: back up, deploy and test the new code, and only then apply
the database migration as a separate, deliberate step.

## The layout marker

`files/.immutable-layout-v1` records that the mounted media volume really is the
one this database belongs to. A fresh install writes it before initializing the
database; `scripts/restore.sh` writes it when it restores media.

If the database says a site is installed but the marker is missing, the container
refuses to start rather than serve a site whose media has silently vanished. In
practice that means the media volume was renamed, removed, or never mounted —
check `docker compose config`, or restore from a backup.

> Deployments created before August 2026 used a single `omeka_files` volume
> mounted over the whole application folder. The one-time migration onto the
> current layout has been retired along with its script; `scripts/restore.sh`
> still reads backups written in that older format.

## What the automated tests cover

Every change to this repository starts a real site three ways and checks it.

With the default storage, the tests confirm that the module and theme folders
are filled from the image, that Omeka's own writeability check passes so the
admin panel offers module management, that a module installed on the running
site appears identically to PHP and to the web server, that it survives the
containers being recreated, and that a full destructive backup-and-restore cycle
brings it back.

With `compose.immutable.yml`, they confirm that nothing under the application
folder can be written to, run the same backup-and-restore cycle, then rebuild
with an extra module on the same storage and check that:

- the added module is present in both the PHP and web images;
- both contain byte-identical module files;
- the database and media survived;
- the application code and the web server's copy of the media are still
  non-writable.

The AMIRA deployment file is started as well, to check that a deployment's own
modules, vocabulary, and extra web server rules still arrive. Separately, the
compose files are rendered in every supported combination and checked against a
list of security rules — including that adding `compose.immutable.yml` in the
wrong position is rejected rather than silently dropping a deployment's
settings.
