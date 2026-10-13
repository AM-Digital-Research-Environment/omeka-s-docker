# Settings reference

Everything you can configure lives in one file. Copy `.env.example` to `.env` and
edit it. Settings marked **rebuild** become part of the image, so changing one
means running `bash scripts/rebuild-code.sh` rather than just restarting.

## Database

| Setting | Required | Default | What it does |
|---------|----------|---------|--------------|
| `MYSQL_PASSWORD` | **Yes** | — | Password for Omeka's database user. Pick a long random one |
| `MYSQL_DATABASE` | No | `omeka` | Name of the database |
| `MYSQL_USER` | No | `omeka` | Database user Omeka connects as |

The database's own root password is generated randomly at first start and is
never needed for day-to-day work.

## The site

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

Serving plain HTTP directly also needs `NGINX_TRUSTED_PROXY_CIDR`; see
[institution setup](INSTITUTION_SETUP.md#minimal-deployment).

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
| `COMPOSE_FILE` | No | — | Switches on a deployment folder, e.g. `docker-compose.yml:compose.amira.yml`. Once set, every `docker compose` command includes it automatically |
| `COMPOSE_PROFILES` | No | — | Switches on optional services, e.g. `search` |
| `AMIRA_MCP_VERSION` | No | see `compose.amira.yml` | AMIRA only: which release of the MCP server to run. Set it with `deploy/amira/update-amira-mcp.sh` |

## What's tuned out of the box

You should not need to change any of this, but it is worth knowing what you have.

**PHP**
- 512 MB memory per request, 100 MB uploads, 5-minute limit on long operations
- Compiled-code and object caching switched on, so pages don't get re-parsed
- ImageMagick, Ghostscript, and PDF tools available for thumbnails and derivatives

**Database**
- 512 MB kept in memory for frequently used data
- Up to 250 simultaneous connections
- See [DB_TUNING.md](DB_TUNING.md) if you need to change any of it

**Web server**
- Compression for text, CSS, JavaScript, and JSON
- Images, fonts, and scripts cached with revalidation, so updates at stable URLs appear
- Security headers, including control over who may embed your site in a frame
- The admin login page is limited to 5 attempts per minute, slowing down
  password guessing
- Only public files are served — see
  [What the site serves](CUSTOMISING.md#what-the-site-serves)
