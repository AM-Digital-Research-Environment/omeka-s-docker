# How code and data are stored

This explains the storage model the template uses, and — for deployments created
before July 2026 — the one-time migration onto it.

If you are setting up a new site, you only need the first section. The migration
does not apply to you.

## The model

**The image is the source of truth for code.** Omeka itself, every module, every
theme, their libraries, and all public assets are installed when the image is
built. Nothing installs code into a running site.

**PHP and the web server are built together.** They are two targets in the same
`Dockerfile`, and the web target copies the finished application folder out of
the PHP one. They therefore always ship exactly the same code — a stylesheet the
browser loads can never come from a different version than the page that asked
for it. This is why the helper scripts always rebuild both.

**Only genuine runtime state is writable:**

| Path | Where it lives | Who can write it |
|---|---|---|
| `/var/www/html/files` | `omeka_media` volume | PHP; the web server reads it read-only |
| `/var/www/html/logs` | `omeka_logs` volume | PHP |
| `/var/lib/php-sessions` | `php_sessions` volume | PHP |
| `/var/www/html/config/database.ini` | Memory only, rewritten on every start, mode `0600` | The startup script |
| `/var/www/html/config/local.config.php` | A file on the host | Nobody — mounted read-only |
| `/tmp` and a few small working directories | Memory only | PHP |
| Everything else under `/var/www/html` | The image | Nobody |

The PHP container's filesystem is read-only apart from those paths.

**A marker file guards against a subtle failure.** `files/.immutable-layout-v1`
records that the media volume really is the migrated one. If Omeka's database
says the site is installed but that marker is missing, the container refuses to
start rather than quietly serve a site whose media has vanished.

## What this buys you

- A rebuild from the same commit produces the same site.
- You can see exactly what is installed by looking at the image, which makes
  vulnerability scanning meaningful.
- Undoing a bad code update is going back to the previous image.
- Someone who finds a way to write files cannot modify the application, and
  cannot get the web server to execute what they write.

The cost is that adding a module is a rebuild rather than a click in the admin
interface. In practice that is one command.

## Updating code

```bash
# Add something new, at a fixed version
bash scripts/install-module.sh gh:owner/repository v1.2.3
bash scripts/install-theme.sh gh:owner/theme 0123456789abcdef

# Apply your own edits to the module or theme lists
bash scripts/rebuild-code.sh

# Re-download anything tracking a branch rather than a fixed version
bash scripts/update-module.sh
```

**A rollback restores code, not the database.** If a new version of Omeka or of a
module has already applied its database migration, going back to the old image
will not undo it. So: back up, deploy and test the new code, and only then apply
the database migration as a separate, deliberate step.

## One-time migration for older deployments

> This applies only to deployments that still have the old `omeka_files` volume
> mounted over the whole application folder. New installations are already on the
> current layout.

Schedule a maintenance window and update your copy of this repository first.
Then:

```bash
bash scripts/migrate-immutable-storage.sh
```

The script takes a backup and runs a read-only check *before* it touches
anything. That check builds the new images and compares the modules and themes
currently deployed — names and versions — against what the new image contains.
Any mismatch stops the migration before the running site is affected.

If something on the old site can't be reproduced from a published release, adopt
the exact files instead:

```bash
bash scripts/migrate-immutable-storage.sh --adopt-code
```

This copies those modules and themes into `_docker/local-modules/` and
`_docker/local-themes/`, then runs the same check again. Review what it copied
and commit it. Later you can usually replace it with a proper fixed version in
`_docker/extra-modules.txt` and get updates back.

Once you confirm, the script:

1. Keeps a mandatory backup under `backups/pre-immutable-*`.
2. Preserves your existing `local.config.php` as a read-only host file.
3. Stops the site and copies only `files/` and `logs/` to their new volumes.
4. Checks the media file count matches, and writes the layout marker.
5. Starts the new stack and verifies the database, PHP, the web server, and that
   the code really is read-only.

**The old `<project>_omeka_files` volume is never deleted.** Keep it until you
have checked the public site, the admin interface, a representative sample of
media, your modules and themes, IIIF if you use it — and have successfully
restored a new-format backup somewhere else.

## What the automated tests cover

Every change to this repository is tested by starting a site with one set of
modules, writing test data to the database and media, doing a full destructive
backup-and-restore cycle, then rebuilding with an extra module on the same
storage. It then checks that:

- the added module is present in both the PHP and web images;
- both contain byte-identical module files;
- the database and media survived;
- the application code and the web server's copy of the media are still
  non-writable.
