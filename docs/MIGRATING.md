# Moving an existing Omeka S site into this stack

This guide is for a site that already runs somewhere else: a classic
Apache/PHP/MySQL server, shared hosting, or another Docker image. You get the
data out of the old site, convert it with `scripts/import-external.sh` into the
same backup format `scripts/backup.sh` writes, and restore that with
`scripts/restore.sh`.

The old site keeps running, unchanged, the whole time. Nothing moves for
visitors until you switch DNS, so you can rehearse as often as you like.

Short version:

```bash
# 1. On the old server (or anywhere with a copy of its files)
bash scripts/import-external.sh --omeka-root /var/www/omeka-s --database omeka-dump.sql

# 2. On the new server, in a checkout of this template, with .env prepared
bash scripts/restore.sh backups/imported-20261120-101500
docker compose exec php omeka-s-cli core:migrate   # if the old site was older
```

## What you need from the old site

| What | Where it is on a classic install | Needed? |
|---|---|---|
| The database, as an SQL dump | MySQL/MariaDB | Yes |
| `files/` (uploaded media and thumbnails) | `<omeka>/files` | Yes |
| `config/local.config.php` | `<omeka>/config` | Recommended |
| `modules/` | `<omeka>/modules` | Recommended |
| `themes/` | `<omeka>/themes` | If a site uses a theme other than `default` |
| The Omeka version | `<omeka>/application/Module.php`, or the admin footer | Read automatically |

You do **not** need `config/database.ini`, the old Omeka core, or `vendor/`.
This stack brings its own Omeka core, PHP 8.5 and MySQL 9, and generates its
own database credentials from `.env`.

Stop editing on the old site before you take the dump and the files, so the
two match. Visitors can keep browsing.

## 1. Get the data out

### a. A server with shell access (LAMP, VM)

Clone this template on the old server; the script needs nothing but bash,
coreutils, GNU tar and gzip there, and never Docker.

```bash
git clone https://github.com/AM-Digital-Research-Environment/omeka-s-docker.git ~/omeka-s-docker
cd ~/omeka-s-docker
bash scripts/import-external.sh --omeka-root /var/www/omeka-s
```

Without `--database` it stops and prints the dump command to run, with the user,
database and host filled in from the old `config/database.ini` (it never prints
the password; `mysqldump` asks for it):

```bash
mysqldump --single-transaction --routines --triggers --no-tablespaces \
  --default-character-set=utf8mb4 -h localhost -u omeka -p omeka > omeka-dump.sql
```

On MySQL (not MariaDB) with GTIDs enabled, add `--set-gtid-purged=OFF`. Then run
the conversion for real, as a user that can read every file under `files/`
(often `sudo`, or `sudo -u www-data`):

```bash
sudo bash scripts/import-external.sh --omeka-root /var/www/omeka-s \
  --database omeka-dump.sql --output ~/omeka-import
```

Copy the output directory to the new server, into the template's `backups/`:

```bash
rsync -a ~/omeka-import/ newserver:omeka-site/backups/omeka-import/
```

If you would rather not run anything on the old server, copy `files/`,
`modules/`, `themes/`, `config/local.config.php` and the dump across and run the
script on the new server with `--files`, `--modules`, `--themes` and `--config`
instead of `--omeka-root`.

### b. Shared hosting: FTP and phpMyAdmin only

**Database.** In phpMyAdmin select the Omeka database, then Export → *Custom*:

- Tables: all of them.
- Output: *Save output to a file*, character set *utf-8*, compression *gzipped*
  (or none).
- Format: *SQL*.
- Format-specific options: leave *Add CREATE DATABASE / USE statement*
  **unticked**; tick *Disable foreign key checks*.
- Object creation options: *Add DROP TABLE* ticked is fine.
- Data creation options: *INSERT*, and keep *Dump binary columns in hexadecimal
  notation* ticked.

A large database can time out in phpMyAdmin. The hosting panel's own database
backup (for example cPanel → Backup → *Download a MySQL Database Backup*)
produces a `mysqldump` file, which the script accepts as `.sql.gz` directly.

**Files.** With an FTP/SFTP client (binary transfer mode), download `files/`
complete, `modules/`, `themes/` and `config/local.config.php`. Downloading
`application/Module.php` as well lets the script read the version; otherwise it
reads it from the database.

Then, on any Linux machine with a checkout of this template:

```bash
bash scripts/import-external.sh --files ./files --database omeka.sql.gz \
  --modules ./modules --themes ./themes --config ./local.config.php
```

If you downloaded the whole Omeka directory, `--omeka-root ./omeka-s` does the
same. The script also accepts `.zip` or `.tar.gz` archives for `--files`,
`--modules` and `--themes`, if the host offers to pack them for you.

### c. Another Docker setup

If the old site already runs this template, use `scripts/backup.sh` instead; it
writes the restore format directly.

Otherwise, dump from the database container. Variable names differ between
images (`docker exec <db-container> env` shows them; the MariaDB image uses
`MARIADB_USER` etc., and calls the tool `mariadb-dump`). Do not use `-t`, which
would add carriage returns to the dump:

```bash
docker exec <db-container> sh -c 'exec mysqldump --single-transaction --routines \
  --triggers --no-tablespaces --default-character-set=utf8mb4 \
  -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' > omeka-dump.sql
```

Copy the files out of the Omeka container. The paths below are the usual ones;
`docker inspect <omeka-container>` shows the real mounts:

```bash
mkdir old-site
docker cp <omeka-container>:/var/www/html/files   old-site/files
docker cp <omeka-container>:/var/www/html/modules old-site/modules
docker cp <omeka-container>:/var/www/html/themes  old-site/themes
docker cp <omeka-container>:/var/www/html/config/local.config.php old-site/
```

```bash
bash scripts/import-external.sh --files old-site/files --database omeka-dump.sql \
  --modules old-site/modules --themes old-site/themes --config old-site/local.config.php
```

## 2. What the conversion checks and writes

`import-external.sh` never changes its sources, refuses to write into an
existing directory, and with `--dry-run` only reports. It checks:

- **files/** contains `original/`, and reports file counts and sizes per
  sub-directory. A missing `large/`, `medium/` or `square/` means thumbnails
  were not copied.
- **The dump** contains Omeka S tables (`resource`, `item`, `media`, `setting`,
  `module`, …), is complete (the `-- Dump completed` trailer of a `mysqldump`
  file), and records which Omeka version it belongs to.
- **MySQL 9 compatibility.** Dumps from recent MariaDB start with
  `/*!999999\- enable the sandbox mode */` and use `utf8mb4_uca1400_ai_ci`
  collations; MySQL rejects both. `--fix-mariadb` removes the sandbox line, maps
  uca1400 collations to `utf8mb4_unicode_ci` and Aria tables to InnoDB.
- **Privileges and database name.** restore.sh imports as the unprivileged
  database user into `MYSQL_DATABASE`. `DEFINER=` clauses, `CREATE DATABASE` /
  `USE` statements and `GTID_PURGED` / `SQL_LOG_BIN` settings break that;
  `--fix-portability` strips them.
  Both fix options are off by default, rewrite only statement lines (never
  `INSERT` data), and report what they changed.
- **The Omeka version**, compared with this template's default `OMEKA_VERSION`.
- **local.config.php** for settings that are wrong in a container: a
  `phpcli_path`, an `imagemagick_dir` other than `/usr/bin`, a custom
  `file_store` path, a non-local `Omeka\File\Store`, S3/AnyCloud settings,
  a session `save_path`, CA paths, absolute host paths. It prints line numbers
  only, because the file may hold secrets. `_docker/local.config.php` is the
  container-safe reference. Without `--config`, that template file is used.
- **Modules and themes** in the old site against the template's defaults
  (`_docker/default-modules.txt`).

The output is a normal backup directory: `BACKUP_FORMAT`, `omeka_db.sql`,
`omeka_media.tar.gz` (with the media layout marker), `local.config.php`,
optional `omeka_modules.tar.gz` and `omeka_themes.tar.gz`, and `SHA256SUMS`.
Every archive entry belongs to uid/gid 33 (`www-data` in the container),
whatever owned the files on the old server.

## 3. Restore on the new server

```bash
git clone https://github.com/AM-Digital-Research-Environment/omeka-s-docker.git omeka-site
cd omeka-site
cp .env.example .env
nano .env
```

In `.env`:

- `MYSQL_PASSWORD`: a new password. The old database credentials are not used.
- `OMEKA_VERSION`: the value the script printed (see below).
- `SERVER_NAME`: the site's host name.
- Leave `OMEKA_ADMIN_*` unset: the accounts come from the old database.

**Which Omeka version.** The script prints the line to set.

- Old site **older** than the template's default: keep the default. The
  database is upgraded with one command after the first start (step 4). The
  container does not migrate automatically.
- Old site **the same**: nothing to do.
- Old site **newer**: set `OMEKA_VERSION` to the old site's version, or update
  the template first. Omeka S cannot downgrade a database.

Build first, so a build problem shows up before anything is restored, then
restore:

```bash
docker compose build
bash scripts/restore.sh backups/omeka-import
```

`restore.sh` verifies every checksum, installs the old `local.config.php` as
`_docker/restored-local.config.php` (and points `OMEKA_LOCAL_CONFIG` at it),
fills the media, modules and themes volumes, imports the database and starts
the stack. See [BACKUP_RESTORE.md](BACKUP_RESTORE.md) for details.

## 4. First start

```bash
docker compose ps               # wait until php is "healthy"
docker compose logs php         # look for errors
docker compose exec php omeka-s-cli core:version
docker compose exec php omeka-s-cli core:migrate   # only if the old site was older
docker compose exec php omeka-s-cli module:list
```

Signing in as an administrator before migrating shows Omeka's own *migrate*
page instead; either way works.

**Modules.** What `module:list` shows, and what to do:

- *needs upgrade*: `docker compose exec php omeka-s-cli module:upgrade <Name>`.
- *not found*: the database knows the module, the volume does not have it.
  Install it with Easy Admin or `omeka-s-cli module:download <Name>`, or re-run
  the import with `--modules`. Until then Omeka treats it as missing, and
  whatever it added to your sites (blocks, data types) does not work.
- *error* or PHP errors in `docker compose logs php`: old module versions may
  not run on PHP 8.5. Update them (Easy Admin, or `omeka-s-cli module:update
  <Name>`), or deactivate them.

How `--modules` behaves: the modules archive **replaces** the modules volume.
You get the old site's modules exactly, but not the template's defaults the old
site lacked (the script lists them; add them with `module:download`). Without
`--modules`, the volume starts with the template's defaults and the old site's
other modules show as *not found*. The same applies to `--themes`. Modules that
are present but not installed are installed automatically on start
(`OMEKA_AUTO_INSTALL_MODULES`).

## 5. Check before switching

- Sign in with an account from the **old** site; passwords are carried over.
- Open a few items: originals and thumbnails both display.
- Admin → Modules: nothing left in *needs upgrade*, *not found* or *error*.
- Each site's public pages, navigation and theme.
- Links: if the old site lived under a sub-path (`example.org/omeka/s/…`), this
  stack serves it at the root (`example.org/s/…`). Fix hard-coded links in page
  content, and keep a redirect on the old host.
- Run one background job (a batch edit, for example) to confirm jobs run.
- Settings → General: administrator email, and anything mentioning the old host.
- Fix any `local.config.php` warnings in `_docker/restored-local.config.php`,
  then `docker compose restart php`.

## 6. Switch DNS, then HTTPS

1. Lower the DNS TTL a day ahead.
2. Freeze editing on the old site. If editors kept working since the first
   import, repeat steps 1 to 3 for a fresh copy; a restore replaces everything,
   including changes made on the new site since.
3. Point DNS at the new server.
4. Set up HTTPS: see [PRODUCTION.md](PRODUCTION.md). The bundled Caddy
   (`compose.tls.yml`) needs DNS to point at the new server first, and makes
   the login cookie Secure itself; behind your own proxy, set
   `OMEKA_SESSION_COOKIE_SECURE=true` once the site is served over HTTPS.
5. Set up backups: [BACKUP_RESTORE.md](BACKUP_RESTORE.md).

**Rollback.** The old server was never changed. Until DNS moves, nothing has
happened for visitors; after it moves, pointing DNS back is the rollback. Only
edits made on the new site in between would need redoing there. Keep the old
server and its last dump until you are confident.

## Troubleshooting

| Message | Cause and fix |
|---|---|
| `No original/ directory in …` | `--files` must point at Omeka's `files/` (the directory containing `original/`), or an archive of it. |
| `This does not look like an Omeka S database dump` | Wrong database, an incomplete export (tables missing), or a different application. Export the whole Omeka S database. |
| `no '-- Dump completed' trailer` | The dump was cut off. Dump again and read the command's errors. |
| restore.sh: `omeka_db.sql cannot be imported into this stack as it is` | Its pre-flight check found one of the problems below, before changing anything. Re-run the import with the option it names (`--fix-mariadb`, `--fix-portability`) and restore the new output. |
| `Unknown command '\-'` during restore | MariaDB sandbox line. Re-run the import with `--fix-mariadb`. |
| `Unknown collation: 'utf8mb4_uca1400_ai_ci'` | MariaDB collation. `--fix-mariadb`. |
| `Access denied; you need … SUPER or SET_ANY_DEFINER` | `DEFINER=` in the dump. `--fix-portability`. |
| `Access denied for user … to database 'old_name'` | `CREATE DATABASE`/`USE` in the dump. `--fix-portability`, or export without them. |
| `… SUPER, SYSTEM_VARIABLES_ADMIN …` with `GTID_PURGED` or `SQL_LOG_BIN` | `--fix-portability`, or dump with `--set-gtid-purged=OFF`. |
| `The old site … is NEWER than this template's default` | Set `OMEKA_VERSION` to the old version, or update the template first. |
| `local.config.php line(s) …` | Edit `_docker/restored-local.config.php` after restore to match `_docker/local.config.php`, then `docker compose restart php`. |
| `Omeka\File\Store is not the local store` / cloud storage | The media is not in `files/`. Download it into `files/original` (and thumbnails) first, or install the same storage module with its credentials. |
| `Output directory already exists` | Choose another `--output`; the script never overwrites. |
| `GNU tar is required` | Run the script on Linux (BSD/macOS tar cannot set the archive owners it needs). |
| `There may not be enough free space` | Use `--output` on a larger disk. Archive inputs need room to unpack too. |
| `Some files … are not readable` | Run the script as a user that can read all of `files/`, for example with `sudo`. |
| restore stops half-way | Fix the cause (usually one of the dump messages above), re-run the import into a new `--output`, and restore again; a restore always starts over. |

The fix options never change your original dump; they write a corrected copy
into the output directory.
