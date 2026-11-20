# Settings reference

Everything you can configure lives in one file. Copy `.env.example` to `.env` and
edit it. Settings marked **rebuild** become part of the image, so changing one
means running `bash scripts/rebuild-code.sh` rather than just restarting.

## Database

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `MYSQL_PASSWORD` | **Yes** | — | Password for Omeka's database user. Pick a long random one. With [file-based secrets](#file-based-secrets-optional) it lives in a file instead |
| `MYSQL_DATABASE` | No | `omeka` | Name of the database |
| `MYSQL_USER` | No | `omeka` | Database user Omeka connects as |

The database's own root password is generated randomly at first start and is
never needed for day-to-day work.

## The site

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `OMEKA_VERSION` | No | `4.2.1` | **rebuild** — which Omeka S release to install. `latest` picks up whatever is newest at build time, which by definition hasn't been tested with this template; you'll get a warning if you use it |
| `OMEKA_ADMIN_EMAIL` | No | `admin@example.com` | E-mail (and login) of the first admin account. The first start always installs Omeka by itself; with all three admin settings set, it creates exactly this account |
| `OMEKA_ADMIN_USERNAME` | No | `Admin` | Display name of that first account |
| `OMEKA_ADMIN_PASSWORD` | No | generated | Its password. Without it (or without the other two) the first install makes up a random password and prints it once in `docker compose logs php` as "Generated admin password": sign in and change it. Used on the first start only: remove all three admin settings from `.env` once the site is up. The site logs a warning at every start while the password is still set |
| `OMEKA_TZ` | No | `UTC` | Timezone, e.g. `Europe/Berlin` |
| `OMEKA_LOCALE` | No | — | Language, e.g. `en_US` |
| `OMEKA_TITLE` | No | — | Site title |
| `OMEKA_SECRET_KEY` | Recommended | — | Key that encrypts secrets at rest (module API keys and similar). Generate once with `openssl rand -base64 32` and never change it: values encrypted with the old key become unreadable. Back it up with `.env` |
| `OMEKA_LOCAL_CONFIG` | No | `./_docker/local.config.php` | Path to your copy of Omeka's own configuration file |
| `OMEKA_SESSION_COOKIE_SECURE` | With HTTPS | `false` (`true` with `compose.tls.yml`) | `true` marks the login cookie *Secure*, so browsers only send it over HTTPS. Set it to `true` whenever the site is served over HTTPS through your own proxy; the [bundled HTTPS overlay](#bundled-https-composetlsyml) does that for you. Leave it `false` for a plain-HTTP install, or logging in stops working |
| `OMEKA_SESSION_COOKIE_SAMESITE` | No | `Lax` | The login cookie's SameSite policy (`Lax`, `Strict` or `None`). `Lax` suits nearly every site |
| `OMEKA_AUTO_INSTALL_MODULES` | No | `true` | At every start, install modules that are present on disk but not yet installed. `false` leaves that to the admin, so a module someone deliberately uninstalled stays uninstalled |

To change Omeka's own settings — thumbnail sizes, where files are stored, how
much gets logged — copy `_docker/local.config.php`, edit your copy, and point
`OMEKA_LOCAL_CONFIG` at it. The site can read that file but never writes to it,
and the backup script always saves whichever copy is actually in use.

## Being reachable

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `NGINX_PORT` | No | `80` | Which port on the machine the site answers on. Use `8080` if something else (an HTTPS proxy) holds port 80 |
| `NGINX_BIND` | No | `127.0.0.1` | Who can reach that port. The default means "this machine only", which is what you want behind an HTTPS proxy. Use `0.0.0.0` to serve plain HTTP directly to the internet |
| `SERVER_NAME` | No | `_` | Your public hostname, e.g. `omeka.example.edu`. The default accepts any name, which is fine only when a proxy sits in front |
| `FRAME_ANCESTORS` | No | `'self'` | Which other websites may embed your site in a frame. Default: only your own. Example: `"'self' https://www.example.org"` |
| `NGINX_API_RATE_LIMIT` | No | `off` | `on` limits how fast each client may call the REST API (`/api`, `/api-local`): after a burst of 20, requests beyond the rate get `429 Too Many Requests`. Off by default so harvesters and scripts keep working as before. Behind a proxy it only sees real client addresses if `NGINX_TRUSTED_PROXY_CIDR` is right. See [API rate limit](PRODUCTION.md#api-rate-limit) |
| `NGINX_API_RATE` | No | `10r/s` | The rate when the limit is on, in nginx's `limit_req` notation: `10r/s` (per second) or `600r/m` (per minute) |
| `NGINX_HSTS_MAX_AGE` | No | `0` | Seconds for a `Strict-Transport-Security` header, which tells browsers to use HTTPS only. Sent only on requests your HTTPS proxy forwarded as HTTPS; `0` sends nothing. Use `31536000` (a year) once HTTPS works — browsers remember it, so don't set it while still testing. You can set HSTS on the proxy instead; don't do both. With `compose.tls.yml` leave it at `0`: Caddy sends the header (`CADDY_HSTS_MAX_AGE`) |
| `NGINX_TRUSTED_PROXY_CIDR` | No | `172.16.0.0/12` | The one address range whose `X-Forwarded-For`/`X-Forwarded-Proto` headers nginx believes: your proxy as the web container sees it. The default covers Docker's usual bridge networks, including the one the bundled Caddy connects from. If Docker hands out `192.168.x`/`10.x` networks instead, set it to that subnet, or every visitor appears as the proxy and Omeka builds `http://` links. With no proxy at all, use `192.0.2.1/32` |

Serving plain HTTP directly also needs `NGINX_TRUSTED_PROXY_CIDR`; see
[institution setup](INSTITUTION_SETUP.md#minimal-deployment).

## Bundled HTTPS (`compose.tls.yml`)

Only with `COMPOSE_FILE=docker-compose.yml:compose.tls.yml` (listed last; see
[the overlay order](INSTITUTION_SETUP.md#overlay-order)). A Caddy container then
takes ports 80 and 443, obtains and renews the certificate, and passes requests
to nginx, which is no longer published on the host (`NGINX_PORT` and
`NGINX_BIND` do nothing). Walkthrough: [PRODUCTION.md](PRODUCTION.md#bundled-https-caddy).

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `SERVER_NAME` | **Yes** | — | The public DNS name(s) the certificate is for, space-separated for several (`"example.org www.example.org"`). Must point at this server. Not `_`: Caddy refuses to start with it |
| `ACME_EMAIL` | No | — | Contact address for the certificate account; Let's Encrypt writes there if renewal keeps failing |
| `ACME_CA` | No | Let's Encrypt production | The certificate authority's ACME directory. Test with `https://acme-staging-v02.api.letsencrypt.org/directory` (untrusted certificates, generous limits) and remove the line once it works: production issues only five identical certificates a week |
| `CADDY_TLS` | No | `acme` | `acme` gets a public certificate as above. `internal` issues one from Caddy's own CA, for a machine without a public DNS name; browsers warn until its root (in the `caddy_data` volume) is trusted |
| `CADDY_HSTS_MAX_AGE` | No | `31536000` | Seconds for the `Strict-Transport-Security` header Caddy sends. Browsers ignore it on untrusted (staging, internal) certificates |
| `CADDY_CPU_LIMIT` | No | `0.25` | CPU cap of the Caddy container |
| `CADDY_MEMORY_LIMIT` | No | `128M` | Memory cap of the Caddy container |

The overlay also defaults `OMEKA_SESSION_COOKIE_SECURE` to `true`; a value set
in `.env` still wins, so remove an old `OMEKA_SESSION_COOKIE_SECURE=false`.
Certificates live in the `caddy_data` volume, which `scripts/backup.sh` saves
and `scripts/restore.sh` puts back.

## Modules, themes, and extras

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `ENABLE_IIIF` | No | `false` | **rebuild** — installs IiifServer, ImageServer, and Mirador for IIIF image viewing |
| `EXTRA_MODULES` | No | — | **rebuild** — modules as a comma-separated list. The `_docker/extra-modules.txt` file is easier to review, so prefer that |
| `EXTRA_THEMES` | No | — | **rebuild** — same, for themes |
| `EXTRA_MODULES_FILE` | No | `_docker/empty-modules.txt` | **rebuild** — points at a second module list. This is how a deployment folder adds its own modules |
| `EXTRA_THEMES_FILE` | No | `_docker/empty-themes.txt` | **rebuild** — the same, for themes |
| `OMEKA_ASSET_REFRESH` | No | `stable` | **rebuild** — forces modules to be downloaded again. `rebuild-code.sh --refresh` sets it for you; you shouldn't need it by hand |

## Search (optional)

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `TYPESENSE_API_KEY` | No | — | Shared secret between the search engine and the search module. Required once search is switched on |
| `TYPESENSE_HOST` | No | `typesense` | Where the site finds the search engine |
| `TYPESENSE_PORT` | No | `8108` | Its port |
| `TYPESENSE_PROTOCOL` | No | `http` | Plain HTTP is correct here — the traffic never leaves the machine |

Search adds little risk:

- **Not reachable from outside.** The search engine opens no port to the
  internet or even to the server itself. Only the site can talk to it.
- **A key is required.** Starting it without `TYPESENSE_API_KEY` makes it exit
  immediately rather than run unprotected.
- **Locked down like everything else**: no special privileges, a read-only
  filesystem, browser access disabled, and capped at half a CPU and 512 MB.
- **Nothing irreplaceable.** The index can always be rebuilt from the database.

## Performance

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `PHP_PM_MAX_CHILDREN` | No | `5` | How many requests the site handles at once. Five fits the memory this container is given; raise both together if you have a bigger server |
| `PHP_PM_START_SERVERS` | No | `2` | How many workers start up immediately |
| `PHP_PM_MIN_SPARE_SERVERS` | No | `1` | Keep at least this many idle and ready |
| `PHP_PM_MAX_SPARE_SERVERS` | No | `3` | Shut down idle workers above this many |
| `PHP_PM_MAX_REQUESTS` | No | `500` | Restart a worker after this many requests, so slow memory leaks can't build up |

All five must be whole numbers greater than zero, or the site refuses to start.
Per-service memory and CPU caps are covered in
[institution setup](INSTITUTION_SETUP.md#resource-limits).

## Adding your own deployment

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `COMPOSE_FILE` | No | — | Switches on overlays and deployment folders, e.g. `docker-compose.yml:compose.amira.yml`. Once set, every `docker compose` command includes it automatically. The order matters: see [overlay order](INSTITUTION_SETUP.md#overlay-order) |
| `COMPOSE_PROFILES` | No | — | Switches on optional services, e.g. `search` |
| `SECRETS_DIR` | With `compose.secrets.yml` | — | The directory holding the secret files (e.g. `./secrets`). See [file-based secrets](#file-based-secrets-optional) |
| `AMIRA_MCP_VERSION` | No | see `compose.amira.yml` | AMIRA only: which release of the MCP server to run. Set it with `deploy/amira/update-amira-mcp.sh` |
| `AMIRA_MCP_CURATOR_VERSION` | With the `curator` profile | — | AMIRA only: the amira-mcp-server ref the curator endpoint is built from: a commit SHA, branch or release tag. No default: until curator mode is released it has to name a ref containing it, including `AMIRA_API_BASE` support. See [the curator endpoint](../deploy/amira/README.md#curator-mcp-endpoint) |
| `AMIRA_CURATOR_UID`, `AMIRA_CURATOR_GID` | With the `curator` profile | `1000` | AMIRA only: the user the curator endpoint runs as. Set them to the owner of the secrets directory so its files can stay readable by that user alone |
| `AMIRA_MCP_MEMORY_LIMIT`, `AMIRA_MCP_HEAP_MB` | No | `512M`, `384` | AMIRA only: memory ceiling of the public MCP server and its JavaScript heap cap in MB. Keep the heap about 128M below the ceiling; raise both together |
| `AMIRA_CURATOR_MEMORY_LIMIT`, `AMIRA_CURATOR_HEAP_MB` | No | `640M`, `448` | AMIRA only: the same for the curator endpoint. Heap plus its 128M cache must stay under the ceiling |
| `AMIRA_CURATOR_SECRETS_DIR` | No | `./deploy/amira/curator-secrets` | AMIRA only: the gitignored directory holding the curator endpoint's Omeka key and token hashes |

## File-based secrets (optional)

By default the four credentials — `MYSQL_PASSWORD`, `OMEKA_SECRET_KEY`,
`TYPESENSE_API_KEY` and `OMEKA_ADMIN_PASSWORD` — sit in `.env` and travel to
the containers as environment variables, so `docker compose config` and
`docker inspect` print them. The `compose.secrets.yml` overlay reads them from
one file each instead, mounted read-only at `/run/secrets/<name>` into only the
services that use them.

What it does and does not hide:

- **Gone from** `.env`, `docker compose config` and `docker inspect` of every
  container.
- **`MYSQL_PASSWORD`** is never in php-fpm's environment (in either mode — the
  entrypoint writes it to a private, in-memory `database.ini` and drops it).
  The db container's own scripts read it from the file.
- **Still in a process environment:** Omeka and the search module read
  `OMEKA_SECRET_KEY` and `TYPESENSE_API_KEY` with `getenv()`, so the php
  entrypoint exports them to php-fpm, and Typesense reads its key from its
  environment. Anyone who can read `/proc/<pid>/environ` inside those
  containers, or run `docker exec`, can still see them — as before.
- **Command lines:** the admin password is passed to `omeka-s-cli core:install`
  on first install, and the db healthcheck and backup/restore pass the
  database password to `mysql -p…` inside the db container, both as before.

### Setting it up

```bash
install -d -m 0700 secrets
( umask 022
  printf '%s' 'a-long-random-database-password' > secrets/mysql_password
  openssl rand -base64 32 | tr -d '\n'        > secrets/omeka_secret_key
  : > secrets/typesense_api_key        # empty: search not configured
  : > secrets/omeka_admin_password     # empty: a password is generated at install
)
```

Then in `.env`, set `COMPOSE_FILE=docker-compose.yml:compose.secrets.yml` and
`SECRETS_DIR=./secrets`, and delete the four variables. All four files must
exist — Compose cannot make a secret optional — but an empty file means
"unset", like an empty variable. The php container refuses to start while one
of the four is still set in `.env`, so nothing is silently ignored.

**Modes:** the directory `0700` and owned by you; the files `0644`. The
containers read the files as different users (MySQL as uid 999, PHP as 33,
Typesense as 10002), and Docker mounts them with their host owner and mode, so
they must be world-readable — the `0700` directory is what keeps other users
on the host out. A `0600` file makes the containers fail at start, naming it.

**Order** in `COMPOSE_FILE`: `docker-compose.yml`, then `compose.immutable.yml`
if you use it, then `compose.secrets.yml`, then deployment overlays such as
`compose.amira.yml`.

### Switching an existing installation

The secrets mode needs the php and typesense images built from this version
(their entrypoints read the `*_FILE` variables). The values stay the same, so
the database is not touched.

```bash
bash scripts/backup.sh                       # as always before a change
bash scripts/rebuild-code.sh                 # php/web images with the new entrypoint
docker compose --profile search build typesense   # only if you run search
install -d -m 0700 secrets
( umask 022
  for name in MYSQL_PASSWORD OMEKA_SECRET_KEY TYPESENSE_API_KEY OMEKA_ADMIN_PASSWORD; do
    # Copy each value from the running php container, exactly as it has it
    # (`docker compose config` would print a "$" as "$$"). Nothing is printed.
    docker compose exec -T php sh -c 'printf %s "$(printenv "$1")"' sh "$name" \
      > "secrets/$(tr 'A-Z' 'a-z' <<< "$name")"
  done
)
```

Check the four files (`ls -l secrets/`; `mysql_password` must not be empty),
then edit `.env`: add `compose.secrets.yml` to `COMPOSE_FILE` (create the line
if there is none: `COMPOSE_FILE=docker-compose.yml:compose.secrets.yml`), add
`SECRETS_DIR=./secrets`, delete the four variables, and recreate:

```bash
docker compose config -q && docker compose up -d
```

`up -d` recreates php, db (and typesense) once, a restart of a few seconds to a
minute while php runs its start-up checks; nothing else changes. To go back,
put the variables into `.env` again and remove the two lines.

### Living with it

- **Changing a file**: bind mounts follow the file itself, and editors replace
  it, so recreate the services afterwards:
  `docker compose up -d --force-recreate php db typesense`.
- **Changing the database password**: the file is read when the database is
  first created and at every connection, but changing it does not change the
  password stored in the database. Change the user's password in MySQL first
  (`ALTER USER`), then the file, then recreate db and php.
- **`docker compose exec php …`** sessions get the container's configured
  environment — here the `*_FILE` paths — not what the entrypoint exported to
  php-fpm. A command that needs the Omeka key or the search key loads them
  itself (`scripts/update-extensions.sh` does this for module updates):

  ```bash
  docker compose exec php sh -c 'export OMEKA_SECRET_KEY="$(cat "$OMEKA_SECRET_KEY_FILE")" TYPESENSE_API_KEY="$(cat "$TYPESENSE_API_KEY_FILE")"; exec omeka-s-cli module:list --base-path /var/www/html'
  ```

- **Backups** include the secret files (`secrets/<name>`, mode `0600`) next to
  `.env`; `scripts/restore.sh` puts back any that are missing, with the modes
  above, and keeps existing ones. See [backup and restore](BACKUP_RESTORE.md).

## What's tuned out of the box

You should not need to change any of this, but it is worth knowing what you have.

**PHP**
- 512 MB memory per request, 100 MB uploads, 5-minute limit on long operations
- Compiled-code and object caching switched on, so pages don't get re-parsed
- ImageMagick, Ghostscript, and PDF tools available for thumbnails and derivatives

**Database**
- 512 MB kept in memory for frequently used data
- Up to 50 simultaneous connections (the site needs about 10)
- Binary logs off: backups use `mysqldump`, which doesn't need them
- See [DB_TUNING.md](DB_TUNING.md) if you need to change any of it

**Web server**
- Compression for text, CSS, JavaScript, and JSON
- Images, fonts, and scripts cached with revalidation, so updates at stable URLs appear
- Security headers, including control over who may embed your site in a frame
- The admin login page is limited to 5 attempts per minute, slowing down
  password guessing
- Only public files are served — see
  [What the site serves](CUSTOMISING.md#what-the-site-serves)
