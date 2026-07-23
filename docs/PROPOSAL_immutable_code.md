# Proposal: separate immutable Omeka code from persistent data

> **Status:** proposed — not yet implemented. Deliberately scoped as its own PR
> because it changes the deploy/rollback/update model and needs a maintenance
> window plus a fresh backup. Filed 2026-07-23 from the production-readiness
> review.

## Problem

`docker-compose.yml` mounts the whole Omeka root as one read-write volume:

```yaml
php:
  volumes:
    - omeka_files:/var/www/html:rw   # core + modules + themes + files + config
```

Docker copies image content into a named volume **only when the volume is
empty**. Once `omeka_files` is populated (i.e. after the very first boot), the
volume *masks* whatever the image ships at `/var/www/html`. Consequences:

- `docker compose up -d --build` can rebuild the image to Omeka 4.2.1 (or bump a
  module/theme) while the container keeps executing the **older** code that
  already lives in the volume. The rebuild silently does nothing.
- Updated modules/themes baked via `modules.txt` never reach an existing
  deployment.
- Image CVE scans and SBOMs describe the image, **not** the code actually
  running from the volume.
- Rollback can't just select the previous image tag — the volume, not the image,
  is the source of truth.
- Every build re-downloads core/modules/themes that an existing install ignores.

The current update path (`scripts/update-omeka.sh`, `scripts/update-module.sh`)
exists precisely to work *around* this — mutating files inside the live volume —
which is why those scripts are destructive and non-atomic.

## Target architecture

Keep **code immutable in the image**; persist **only mutable data** on volumes.

Omeka S writes to exactly these paths at runtime:

| Path | Nature | Handling |
|------|--------|----------|
| `files/` | uploaded media, thumbnails, temp, sideload originals | **volume** (already have `omeka_files` — repoint it here) |
| `logs/` | application log | **volume** (or ship to stdout) |
| `config/database.ini` | generated secret (entrypoint writes it) | small **volume** or regenerate on boot into a `tmpfs` |
| `config/local.config.php` | optional local overrides | bake into image, or mount read-only if deployment-specific |
| everything else (`application/`, `modules/`, `themes/`, `vendor/`, `index.php`, `.htaccess`) | code | **baked in image, no mount** |

Sketch:

```yaml
php:
  volumes:
    - omeka_media:/var/www/html/files:rw
    - omeka_logs:/var/www/html/logs:rw
    - omeka_config:/var/www/html/config:rw      # or regenerate database.ini on boot
    - ./uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
    - php_sessions:/var/lib/php-sessions:rw     # already separate — good pattern
```

The web (nginx) service mounts the same **media** volume read-only (it only
needs to serve `/files/...` and the baked assets, which now come from the image
layer it shares):

```yaml
web:
  volumes:
    - omeka_media:/var/www/html/files:ro
    # ...plus the image's /var/www/html for assets — see "Open question" below.
```

## What this unlocks

- `docker compose build && docker compose up -d php` deploys new core/modules/
  themes deterministically. Update becomes "build a new image, swap it in."
- Rollback = redeploy the previous image tag.
- Scans/SBOMs describe what actually runs.
- `scripts/update-*.sh` collapse into a rebuild; the destructive in-place mutation
  goes away.

## Migration (needs a maintenance window + fresh backup)

1. `scripts/backup.sh` — full DB + `files/` backup first.
2. Introduce the new volumes; **seed `omeka_media` from the current
   `omeka_files:/var/www/html/files`** (e.g. `docker run --rm -v omeka_files:/src
   -v omeka_media:/dst alpine cp -a /src/files/. /dst/`). Same for `logs/` and
   `config/`.
3. Bake all currently runtime-installed modules/themes (`EXTRA_MODULES`,
   `EXTRA_THEMES`, IIIF, DRE) into the image via the existing `modules.txt`
   build-arg path so nothing is lost when the code volume is dropped.
4. Swap the compose mounts; `docker compose up -d --build`.
5. Verify: front page, admin, a known media file under `/files/...`, module list,
   IIIF manifest.
6. Retire `omeka_files` once confirmed.

## Open questions / risks

- **nginx needs the code too** (it serves `/application/asset/...`, module/theme
  assets). Either share the image filesystem with web (build web from the same
  image, or copy assets in) or keep serving assets through PHP. Decide before
  implementing.
- **Runtime module install** (`EXTRA_MODULES` in `.env`) is incompatible with an
  immutable code layer — it must move fully to build time. This is the main
  behavioural change for operators.
- The `sideload/` bind mount stays as-is (host ingest dir).
- One-shot data migration must be idempotent and reversible (keep `omeka_files`
  until verified).

## CI regression test to add alongside

Build an image at module set A, boot, assert a module is **absent**; rebuild at
module set A+B on the *same volumes*, redeploy, assert the new module is now
**present**. This would have caught the volume-masking behaviour.
