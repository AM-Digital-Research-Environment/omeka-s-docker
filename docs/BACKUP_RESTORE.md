# Backup, restore, and server migration

## What is in a backup

Every backup is a folder of files. `BACKUP_FORMAT` records the version and which
storage layout the site was on when it was taken.

| File | What it holds |
|---|---|
| `omeka_db.sql` | The database — items, users, settings, everything |
| `omeka_media.tar.gz` | Uploaded files and the thumbnails made from them |
| `omeka_modules.tar.gz` | The modules the site is running |
| `omeka_themes.tar.gz` | The themes the site is running |
| `omeka_logs.tar.gz` | Omeka's log files |
| `local.config.php` | Your copy of Omeka's own configuration file |
| `images.json` | Which images the site was running, for the record |
| `sideload.tar.gz` | The sideload folder, if it has anything in it |
| `.env` | All your settings — **including passwords** |
| `SHA256SUMS` | A checksum for every file above |

Modules and themes are included because the running site owns them: they can be
added and updated from the admin panel, so the image is no longer a record of
what a site actually has. A site that has only ever run with
`compose.immutable.yml` keeps them in the image and has no such storage, so
those two archives are simply absent from its backups.

### What is deliberately left out

| Not backed up | Why |
|---|---|
| Omeka itself and its libraries | They come from the image. The repository, at the revision you built from, is the record of them; deployment configuration is backed up separately |
| Typesense search index | Derived from Omeka; a live filesystem copy is not a supported database snapshot |
| Login sessions | Nothing worth keeping; people simply log in again |
| `dre_visualizations_data` (AMIRA only) | Rebuilt from the database by the admin "Regenerate" action |

This is why the repository matters as much as the backup: the backup holds your
data and settings, the repository holds the recipe for Omeka. Keep both, and
note which commit you built from.

### Restoring archives written before August 2026

Backups from the older storage layout — a single volume covering the whole
application folder, recorded as `layout=legacy` with an `omeka_files.tar.gz` —
can still be restored. Restore takes only the uploaded files, the logs, and
`local.config.php` from them; old code is never put back into a running site,
because code comes from the image.

New backups are always written in the current format. Nothing produces a legacy
archive any more, so this is a read path kept for archives you already hold.

## Making a backup

```bash
# Lands in backups/<date-and-time>/
bash scripts/backup.sh

# Or somewhere you choose
bash scripts/backup.sh /path/to/backup-dir
```

**By default, the site stays up throughout.** The database is captured as one consistent
snapshot without blocking anyone, and the files are read without being locked.

**One thing to avoid**: don't install or upgrade a module, or apply an Omeka
upgrade, while a backup is running. Those change the shape of the database, and
that kind of change is the one thing the snapshot cannot protect against.
Browsing is safe. Avoid uploads, file replacement, and deletion during a backup
if you need the media to match the database snapshot exactly: a file deleted
after the SQL snapshot may disappear before the archive reads it. For a strict
point-in-time backup, pause editing/import jobs for the entire backup window.

The database and the files are also captured a few minutes apart, not at the
same instant, which is another reason to keep several backups rather than
relying on the newest one.

Use an empty destination directory. Relative paths are resolved before Docker
mounts them. `BACKUP_INCOMPLETE` remains present if any step fails; restore
refuses such a directory. Successful completion writes `SHA256SUMS` and removes
that marker. Do not remove it manually to make an interrupted backup restorable.

For a matched SQL/media backup, run `bash scripts/backup.sh --quiesce`. This
stops running web/PHP services, including their jobs, and restarts those same
services on exit even if archiving fails. Pause external writers separately.

New backups omit Typesense. Rebuild its index from the restored Omeka database
before enabling search for users. Older `typesense_data.tar.gz` archives remain
readable with `scripts/restore.sh --restore-search`, but are skipped by default:
they are best-effort live copies, not supported database snapshots.

Volume names are resolved from active Compose mounts, including custom names.
Old, unmounted extension volumes are ignored. Bind mounts for media, logs or
the database are not supported by these helpers and fail before data operations.

The backup folder is readable only by the user who made it, and `.env` and
`local.config.php` more tightly still. The checksums tell you whether a copy
arrived intact — they are not encryption. **A backup contains your `.env`, and
therefore your passwords, so encrypt it before it goes anywhere else**, and keep
at least one copy off this server that you have actually tried restoring.

## Restoring

```bash
bash scripts/restore.sh backups/20260731-120000

# Skip the confirmation prompt — for automation only
bash scripts/restore.sh --force backups/20260731-120000
```

Restore checks every checksum before it changes anything, and warns you if it is
about to overwrite storage that already has something in it. It puts the
configuration file back as `_docker/restored-local.config.php` for you to review
rather than overwriting yours, recreates the database, and starts the site.

**Restoring replaces what is there, and it cannot be half-done.** If it is
interrupted, fix whatever stopped it and run it again from the same backup.

## Moving to another server

1. Make a backup on the old server, and keep it.
2. On the new server, check out the same commit of this repository.
3. Copy the whole backup folder across, with `rsync` or `scp`.
4. Run `bash scripts/restore.sh <backup-folder>`.
5. Wait for `docker compose ps` to say everything is healthy.
6. Check the admin login, a sample of media, your modules and themes, IIIF if
   you use it, and search if you use it.
7. Only then point DNS at the new server.

Step 2 matters as much as the backup: the backup holds your data, and the
repository at that commit is what rebuilds the same Omeka around it.

## A retention schedule to copy

Keep a week of nightly backups:

```cron
0 3 * * * cd /path/to/omeka-s-docker && bash scripts/backup.sh && find backups/ -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
```

Try a restore now and then, into a separate copy of the site, and keep the
previous backup until you have actually clicked around the restored one — not
merely watched it start.
