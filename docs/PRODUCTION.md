# Production deployment

A walk-through for taking this Omeka S stack from a local install to a publicly reachable, TLS-terminated, hardened site.

The site itself speaks plain HTTP. For a public site, put something in front of
it that handles HTTPS certificates. Whichever you choose, Omeka produces correct
`https://` links, emails, and IIIF manifests automatically, as long as the proxy
forwards the usual `X-Forwarded-Proto` header (Caddy, Traefik, and standard
nginx all do). Set `SERVER_NAME` in `.env` to your public hostname.

## Choosing a proxy

| Your situation | Use |
|---|---|
| One server with a public DNS name, nothing else on ports 80/443, "I just want HTTPS" | [Bundled HTTPS (Caddy)](#bundled-https-caddy) — three lines in `.env` |
| Existing institutional certificates, central ACME, several sites on one host, or a proxy you already run | [Host nginx](#1-architecture) (sections 1–5 below), or your own Caddy/Traefik |

### Bundled HTTPS (Caddy)

`compose.tls.yml` adds a Caddy container in front of the site. It obtains a
Let's Encrypt certificate for your hostname, renews it on its own, redirects
HTTP to HTTPS and sends HSTS. Nothing is installed on the host.

1. **DNS.** Point an `A` record (and `AAAA` if the server has IPv6) for your
   hostname at the server. Check: `dig +short omeka.example.org`.
2. **Ports.** 80 and 443 must reach the server from the internet (firewall:
   [section 4](#4-firewall), plus `443/udp` for HTTP/3 if you like; browsers
   fall back to TCP without it) and nothing else on the host may listen on
   them. Port 80 stays open after setup: Caddy answers renewal challenges and
   redirects there.
3. **`.env`.** Add:

   ```bash
   COMPOSE_FILE=docker-compose.yml:compose.tls.yml
   SERVER_NAME=omeka.example.org
   ACME_EMAIL=admin@example.org   # optional: expiry warnings from Let's Encrypt
   ```

   With other overlays, `compose.tls.yml` comes last, e.g.
   `docker-compose.yml:compose.immutable.yml:compose.secrets.yml:compose.tls.yml`
   ([overlay order](INSTITUTION_SETUP.md#overlay-order)). It replaces a host
   proxy, so it does not go together with a deployment that has one, such as
   `compose.amira.yml`.
4. **Start.** `docker compose up -d`, then watch the certificate arrive:
   `docker compose logs -f caddy` (look for `certificate obtained successfully`).
5. **Check** from another machine:

   ```bash
   curl -sI http://omeka.example.org/ | head -3    # 308 to https://
   curl -sI https://omeka.example.org/ | grep -iE '^HTTP|^strict-transport'
   echo | openssl s_client -connect omeka.example.org:443 -servername omeka.example.org 2>/dev/null \
       | openssl x509 -noout -issuer -dates
   ```

What the overlay sets for you: the web container is no longer published on the
host (only Caddy is), the login cookie is `Secure`
(`OMEKA_SESSION_COOKIE_SECURE=true`, unless `.env` still says `false` — remove
that line), and HSTS comes from Caddy (`CADDY_HSTS_MAX_AGE`), so leave
`NGINX_HSTS_MAX_AGE` at 0: the [HTTPS settings](#https-settings-in-env) below
are for a host proxy. Real visitor addresses reach Omeka and the rate
limits because nginx trusts Caddy's `X-Forwarded-*` headers through
`NGINX_TRUSTED_PROXY_CIDR`; its default covers Docker's usual 172.16–31.x
networks. If `docker network inspect <project>_frontend` (e.g.
`omeka-s-docker_frontend`) shows a different subnet (192.168.x on hosts with many networks), set that subnet
there, or every visitor appears as Caddy and Omeka builds `http://` links.

**Certificates** live in the `caddy_data` volume (project prefix in front, e.g.
`omeka-s-docker_caddy_data`), which `scripts/backup.sh` saves and
`scripts/restore.sh` puts back. Renewal is automatic, well before expiry, as
long as the stack runs and port 80 stays reachable. Do not delete
that volume: a fresh one makes Caddy request new certificates, and Let's
Encrypt allows only five identical ones per week. While experimenting, use the
staging CA (untrusted certificates, generous limits), then remove the line:

```bash
ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
```

**No public DNS name** (a lab machine, a LAN name): `CADDY_TLS=internal`
makes Caddy issue the certificate from its own local CA. Browsers warn until
you trust its root, `docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt .`.

The other knobs are `CADDY_HSTS_MAX_AGE` and `CADDY_CPU_LIMIT`/
`CADDY_MEMORY_LIMIT` ([CONFIGURATION.md](CONFIGURATION.md)); the Caddy
configuration itself is `_docker/caddy/Caddyfile`.

**Moving to a host proxy later:** remove `compose.tls.yml` from
`COMPOSE_FILE`, then `docker compose up -d --remove-orphans` stops Caddy and
publishes the web container on the loopback again. Set `NGINX_PORT=8080`
([section 2](#2-free-port-80-on-the-host)) and `OMEKA_SESSION_COOKIE_SECURE=true`
in `.env` first: the overlay no longer supplies the latter. Continue with
section 3. To reuse the
certificate meanwhile, copy it out of `caddy_data`
(`/data/caddy/certificates/`) before removing the volume.

### Host nginx, or your own Caddy/Traefik

The rest of this guide walks through a standalone nginx on the host, with
everything around it: firewall, certificate provisioning, host hardening,
verification. It suits institutional setups: certificates pushed by central
IT, several sites behind one proxy, an ACME client you already run.

Your own Caddy on the host works the same way with a two-line Caddyfile
(`omeka.example.edu { reverse_proxy 127.0.0.1:8080 }`) after section 2; so
does Traefik, with labels on the `web` service in a
`docker-compose.override.yml`. With either, only sections **2** and **6**
onward still apply; they handle TLS and the redirect themselves. Whatever
proxy you use must forward `X-Forwarded-Proto` (all three do), and then
set the [HTTPS settings](#https-settings-in-env) in `.env`.

## What the template already hardens

| | |
|---|---|
| **The database is unreachable** | It has no port open to the machine or the internet — only the site can talk to it |
| **The site itself listens locally by default** | It expects an HTTPS proxy in front |
| **Nothing runs as root** | Omeka and the database run as unprivileged users, and containers can't gain new privileges |
| **The database and search engine can't reach the internet** | Their network has no route out, so a compromised one can neither phone home nor download anything |
| **Process limits** | Each service has a cap on processes and threads, so a runaway process can't exhaust the machine |
| **Omeka's own code can't be modified** | Omeka, its libraries, and its configuration are read-only while running. The module and theme folders are writable, because the admin panel manages them — [lock those down too](IMMUTABLE_CODE.md#locking-modules-and-themes-down) if you'd rather they weren't |
| **Only one PHP file can execute** | See [What the site serves](CUSTOMISING.md#what-the-site-serves) |
| **Private files aren't served** | Configuration, logs, source code, and dependency lists all return 404 |
| **Resource limits** | Each service has a CPU and memory cap, so one misbehaving part can't take the machine down |
| **Login is rate-limited** | 5 attempts per minute on the admin login page |
| **API rate limit, if you want it** | `NGINX_API_RATE_LIMIT=on` caps each client on the REST API; see [below](#api-rate-limit) |
| **Versions are locked** | Every image is pinned to an exact published build, so a rebuild can't silently pull something different |

What is left to you: HTTPS (the [bundled overlay](#bundled-https-caddy) or this guide, including the [HTTPS settings](#https-settings-in-env)
in `.env`), keeping `.env` out of Git and encrypting backups (they contain it),
removing the three `OMEKA_ADMIN_*` values from `.env` once the first account
exists (the site logs a warning at every start until you do), scheduled
off-host backups, and treating Docker access on the host as root access. Consider
scanning your images for known vulnerabilities, e.g.
`docker scout cves omeka-s-docker-php:latest`. Committed database transactions
are flushed to disk by default; for the trade-off see
`innodb-flush-log-at-trx-commit` in [DB_TUNING.md](DB_TUNING.md).

---

## 1. Architecture

```
              Public internet
                    │
              ┌─────▼──────┐
              │   :443     │   host firewall (ufw): allow 80, 443, ssh
              └─────┬──────┘
                    │ TLS terminated here
              ┌─────▼──────────┐
              │  host nginx    │   (apt-installed; reads /etc/ssl/... certs)
              │  reverse proxy │
              └─────┬──────────┘
                    │ plain HTTP, X-Forwarded-Proto: https
              ┌─────▼──────────┐
              │  127.0.0.1:8080│
              │  container     │   nginx (from this template)
              │  nginx         │
              └─────┬──────────┘
                    │ FastCGI
                    ▼
                php-fpm  ─→  mysql
                (container)   (container)
```

The host nginx terminates TLS and forwards `X-Forwarded-Proto: https` to the container; the container nginx maps that to PHP-FPM's `HTTPS=on` so Omeka generates correct `https://` URLs in IIIF manifests, emails, and redirects.

## 2. Free port 80 on the host

By default the container takes port 80, on the loopback interface only
(`NGINX_BIND=127.0.0.1`). Move it to 8080 so the host nginx can take 80 and 443:

```bash
# In .env
NGINX_PORT=8080
```

```bash
docker compose up -d --force-recreate web
ss -tlnp | grep -E '127\.0\.0\.1:(80|8080)'   # expect only :8080
```

Leave `NGINX_BIND` at its default. It means the container is reachable only from
the server itself, so nothing can bypass the proxy and reach the site over plain
HTTP. Setting it to `0.0.0.0` is only for the case where you deliberately want to
serve HTTP directly with no proxy at all — and it also weakens the rate limiting,
since a client on a private network could then claim any IP address it likes.

Set `NGINX_TRUSTED_PROXY_CIDR` to the proxy or Docker gateway address as seen by
the web container. The default covers ordinary Docker bridge addresses; custom
10.x/192.168.x bridges need an explicit setting. For direct HTTP with no proxy,
use `192.0.2.1/32` so no real client's forwarded IP/HTTPS headers are trusted.
See [institution setup](INSTITUTION_SETUP.md) for examples and resource sizing.

## 3. Install and configure the host nginx

```bash
sudo apt-get install -y nginx
```

Write `/etc/nginx/sites-available/yoursite.conf`:

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

Key points:

- The HTTP block redirects to HTTPS **except** for `/.well-known/acme-challenge/` — needed if you use certbot HTTP-01 challenges.
- `client_max_body_size 100M` to match the container's upload limit.
- Forward `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host`.
- HSTS is **commented out** in the example. Leave it commented until your first successful real-cert load (see section 5), then uncomment and reload.

Enable and test:

```bash
sudo ln -sf /etc/nginx/sites-available/yoursite.conf /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

If `nginx -t` fails complaining about missing certs, drop a temporary self-signed pair in place so nginx can start:

```bash
sudo mkdir -p /etc/ssl/yoursite
sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout /etc/ssl/yoursite/privkey.pem \
    -out    /etc/ssl/yoursite/fullchain.pem \
    -subj   "/CN=omeka.example.edu" \
    -addext "subjectAltName=DNS:omeka.example.edu"
sudo chmod 600 /etc/ssl/yoursite/privkey.pem
```

Then point your nginx `ssl_certificate` / `ssl_certificate_key` at those files. The self-signed cert is just so nginx starts; replace as soon as you have a real one (next section).

## 4. Firewall

If you use UFW:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'      # don't lock yourself out
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw --force enable
sudo ufw status verbose
```

If the host sits behind an upstream institutional firewall, you'll also need that opened for ports 80/443 to your VM's public IP — that's a separate request to whoever owns the network.

## 5. TLS certificate

Three common provisioning paths. Pick one and ignore the others.

### 5a. Institutional ACME automation (DFN-PKI / HARICA / central ITS)

Many universities run a central ACME server (GÉANT TCS via HARICA, DFN-PKI, etc.) that issues, deploys, and renews certs without per-host certbot. Typical workflow:

1. Tell your IT contact the FQDN you want a cert for.
2. They push `fullchain.pem` and `privkey.pem` into a known directory on your VM (often something like `/.cert/`, `/etc/ssl/<host>/`, or whatever convention they use) and reload nginx.
3. Point your nginx `ssl_certificate` paths at those filenames.
4. Renewals happen on their schedule, automatically.

You install **no ACME client locally** in this case — clashes with their automation.

### 5b. Let's Encrypt with certbot

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d omeka.example.edu
```

Certbot will edit your nginx config to use the issued cert and set up a renewal timer. The HTTP block's `/.well-known/acme-challenge/` location is what makes HTTP-01 challenges work.

### 5c. Manual / external CA

Drop the issuer-supplied `fullchain.pem` and `privkey.pem` into your TLS directory and reload:

```bash
sudo systemctl reload nginx
```

### After the real cert is in: enable HSTS

Confirm `https://yoursite/` validates without `-k`:

```bash
curl -sI https://omeka.example.edu/ | head -3   # expect 'HTTP/2 200', no errors
```

Then uncomment the HSTS line in the nginx site config and reload:

```nginx
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
```

Don't enable HSTS while testing with a self-signed cert — browsers will pin the bad state and refuse to load until the max-age expires.

Instead of the host nginx line, you can let the container send the header:
set `NGINX_HSTS_MAX_AGE=31536000` in `.env` and run `docker compose up -d web`.
It is sent only on requests the proxy forwarded as HTTPS. Use one or the other,
not both.

### HTTPS settings in `.env`

Once the site is served over HTTPS, set in `.env` and apply with
`docker compose up -d php web`:

```bash
OMEKA_SESSION_COOKIE_SECURE=true   # login cookie only ever sent over HTTPS
NGINX_HSTS_MAX_AGE=31536000        # unless HSTS is set on the proxy instead
```

Keep `OMEKA_SESSION_COOKIE_SECURE=false` on a plain-HTTP install: browsers
drop a Secure cookie there and nobody can log in.

## 6. Host-OS hardening (optional but recommended)

Quick wins that knock down low-severity findings on most vulnerability scanners (Greenbone, Nessus, Qualys):

```bash
# Hide system uptime
echo 'net.ipv4.tcp_timestamps = 0' | sudo tee /etc/sysctl.d/99-hardening.conf
sudo sysctl --system

# Drop ICMP timestamp requests at the firewall
# (in /etc/ufw/before.rules, before the COMMIT of the filter table):
#   -A ufw-before-input  -p icmp --icmp-type timestamp-request -j DROP
#   -A ufw-before-output -p icmp --icmp-type timestamp-reply  -j DROP
sudo ufw reload

# Disable weak SSH MACs and DHE key exchange
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
MACs -umac-64-etm@openssh.com,umac-64@openssh.com
KexAlgorithms -diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256
EOF
sudo sshd -t && sudo systemctl reload ssh
```

Keep an existing SSH session open while reloading sshd — if a config error breaks it, you can roll back from the live session.

A note on SSH version scanners: Debian/Ubuntu LTS releases backport security patches into the same upstream version (e.g. `openssh 9.6p1` ships with regreSSHion, Terrapin, MitM patches all backported). Banner-based scanners report these CVEs as "present" — they are false positives. Check the package changelog (`apt changelog openssh-server | grep -i CVE-`) to confirm.

## 7. Backups and operations

Set up a daily backup as soon as the site has real content:

```bash
# /etc/cron.d/omeka-backup  (replace <user> and the path)
0 3 * * * <user> cd /path/to/omeka-s-docker && bash scripts/backup.sh --keep 7
```

Each snapshot is a full database + media copy, so set `--keep` from day one.
It prunes only after the new snapshot is complete and checksummed. Use
`--keep 1` when an off-host incremental archiver holds the real history.

Nothing runs a backup until you add that cron entry, and a backup on the same
disk is lost with the disk: copy each snapshot off the host as well.
[BACKUP_RESTORE.md](BACKUP_RESTORE.md#a-retention-schedule-to-copy) has a
schedule to copy, including the off-host step.

### Disk housekeeping

Image rebuilds leave build cache and superseded images behind, and Docker never
removes them on its own; the reference host had accumulated 27 GB of build
cache and 11 GB of unused images. Every month or so, and after a round of
updates:

```bash
docker system df             # what is using the space
docker builder prune -f      # build cache; the next build is slower once
docker image prune -a -f     # images no container uses, including old releases
```

Both leave running containers, volumes and their data alone. `image prune -a`
also deletes images of services that are currently stopped (an opt-in profile
you switched off, say); they are rebuilt or pulled the next time they start.
Never add `--volumes` to a prune: volumes hold the database and the media.

### API rate limit

The public REST API (`/api/…`, and `/api-local/…`, the same data without key
authentication that the admin forms also call) is not rate-limited by default:
harvesters, IIIF viewers and sites that read from each other differ too much
for one number. To cap it per client address, set in `.env` and apply with
`docker compose up -d web`:

```bash
NGINX_API_RATE_LIMIT=on
NGINX_API_RATE=10r/s     # the default; nginx syntax, e.g. 300r/m
```

A client may burst 20 requests at once, then gets `429 Too Many Requests`
above the rate. The admin interface stays far below it. Before turning it on,
check who calls the API (`docker compose logs web | grep ' /api'`): an
in-stack client, such as a crawler or indexer container calling `http://web/api`,
is one address and is throttled like any visitor. Keys do not exempt a client.

### Host settings

Worth setting once on the host:

- **Keep containers running while Docker restarts.** In
  `/etc/docker/daemon.json`, then `sudo systemctl restart docker` (that one
  restart still stops the containers):

  ```json
  { "live-restore": true }
  ```

  Docker daemon upgrades and restarts then no longer take the site down.
- **Swap less on small hosts.** On a host with 4 GB or so, the kernel's default
  `vm.swappiness=60` pushes the database's buffer pool out to swap while page
  cache stays. `echo 'vm.swappiness = 10' | sudo tee /etc/sysctl.d/99-swappiness.conf && sudo sysctl --system`.
- **Hide the host nginx version.** Add `server_tokens off;` to the `http` block
  of `/etc/nginx/nginx.conf` (the container's nginx already does this).

### PHP-FPM sizing

`PHP_PM_MAX_CHILDREN` (default 5) is how many requests PHP handles at once;
further requests wait in a queue. Read the counters from the FPM status page:

```bash
docker compose exec php sh -c 'env -i REQUEST_METHOD=GET SCRIPT_NAME=/status \
    SCRIPT_FILENAME=/status QUERY_STRING=full cgi-fcgi -bind -connect 127.0.0.1:9000'
```

The counters run since `start time`:

- `max children reached` — how often every worker was busy. FPM also logs
  `server reached pm.max_children setting` each time (`docker compose logs php`).
- `max listen queue` — the most requests that ever waited for a worker. Above
  0 means visitors waited.
- `last request memory` (per process, in the `full` output) — what a typical
  request needs.

If both counters keep growing in normal traffic and the container's real memory
use leaves room (the cgroup `anon` figure, see below), raise
`PHP_PM_MAX_CHILDREN` and apply with `docker compose up -d php`. The reference
site hit the 5-worker cap 82 times in four days while using 178M of a 1408M
limit, so it had room for more workers. Size it as workers × typical request
memory, plus headroom for a few heavy ones (imports, thumbnails: up to 512M
each), and keep the database's `max-connections` (50) well above it. Raise
`PHP_PM_MAX_SPARE_SERVERS` along with it so idle workers are kept around.

See [BACKUP_RESTORE.md](BACKUP_RESTORE.md) for full backup/restore procedures and [OMEKA_CLI.md](OMEKA_CLI.md) for routine site management via `omeka-s-cli`.

## 8. Verification checklist

After all of the above, confirm from an **external** network (not the VM itself, not a peer in the same datacenter):

```bash
# Cert is real and validates
curl -sI https://omeka.example.edu/ | grep -E '^HTTP|^server|^strict-transport'

# Cert details
echo | openssl s_client -connect omeka.example.edu:443 -servername omeka.example.edu 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# HTTP correctly redirects to HTTPS
curl -sI http://omeka.example.edu/ | head -3   # expect 301 + Location: https://...

# Omeka generates correct https:// URLs
curl -s https://omeka.example.edu/ | grep -oE 'https?://[^"]*omeka.example.edu[^"]*' | head -5

# Session cookie is Secure (OMEKA_SESSION_COOKIE_SECURE=true)
curl -sI https://omeka.example.edu/login | grep -i '^set-cookie'
```

You should see:
- `HTTP/2 200` and a `strict-transport-security` header (if HSTS is enabled).
- An issuer string for a real CA, validity dates a few months in the future, and the SAN matching your hostname.
- A `301` redirect from HTTP to HTTPS.
- Only `https://` URLs in the rendered HTML.
- A `Set-Cookie` line containing `secure` (and `samesite=lax`).

If any of these fail, the [Troubleshooting section of COMMANDS.md](COMMANDS.md#troubleshooting) has the usual culprits.

## 9. Applying changes to a live installation

Working order for any change that rebuilds images or touches the database:

1. Run the CI smoke suite in an **independent, disposable** checkout — never
   against production data (it ends with `docker compose down -v`).
2. Re-read [institution setup](INSTITUTION_SETUP.md), especially proxy trust,
   resource limits and custom volume names.
3. Take a backup. Use `--quiesce` when SQL/media consistency matters, and pause
   external writers as well.
4. Rebuild matching PHP and web images: `bash scripts/rebuild-code.sh --pull`.
5. If the change is to the `db` service's `command`, apply it with
   `docker compose up -d db` inside the maintenance window — the application
   rebuild helper does not necessarily recreate an already-running database.
   Changes to a network's settings (such as `backend` becoming internal)
   recreate that network and every container on it — run a plain
   `docker compose up -d` in the window. If Compose refuses because the
   network is still in use, `docker compose down` (never with `-v`) and then
   `docker compose up -d`.
6. Run `bash scripts/health-report.sh`, then check public and admin pages, a
   media upload, thumbnail generation, background jobs and search. Measure
   memory during a real import.
7. Verify off-host backups by an independent restore, plus TLS renewal and the
   externally exposed ports.

## 10. Operational cautions

These are the limits of what this stack guarantees. None of them is a defect to
fix; they are the things to know before trusting an assumption.

- **`docker compose down -v` destroys the database, media and sessions.** There
  is no undo. It appears in [COMMANDS.md](COMMANDS.md) only as a deliberate
  "start over" step and in the CI smoke tests, which is why those refuse to run
  in a checkout that already has an `.env`.
- **Docker does not restart a container merely because it is unhealthy.** The
  `unless-stopped` policy reacts to a container *exiting*. A wedged-but-running
  service stays wedged until someone looks, so wire
  `bash scripts/health-report.sh` into whatever monitoring you already run.
- **Backups are not atomic unless every writer is stopped.** The SQL dump is a
  consistent InnoDB snapshot, but the media archive is taken afterwards, so an
  upload that lands between the two is in one and not the other. `--quiesce`
  closes the window for web and PHP; external writers are yours to pause.
- **Extension replacement and database migrations are not transactional.** An
  interrupted module update can leave code and schema out of step. Re-running
  `scripts/update-extensions.sh` applies whatever migrations remain pending.
- **PHP's container cap is not a per-request cap.** Five concurrent 512M
  requests can exceed the default 1536M before OPcache, APCu and tmpfs are
  counted. The `OOMKilled` flag also does not catch every worker-level OOM —
  check host and kernel logs when diagnosing a mysterious 502.
- **Pinned base images do not make a rebuild reproducible on their own.** Some
  upstream extension references track a branch by design, so two builds of the
  same commit can contain different module code. Use reviewed release-archive
  URLs in your own manifests where reproducibility matters —
  `scripts/update-module.sh` keeps those pins moving deliberately and leaves a
  reviewable diff; a branch ref leaves no such record.
- **The media layout marker detects uninitialized storage, not a matched pair.**
  `.immutable-layout-v1` stops the stack booting an installed database against
  an empty media volume. It is not a cryptographic association between a
  specific database and a specific media volume.
- **AMIRA only:** precomputed visualizations are not backed up. After a
  restore, run the DreVisualizations admin "Regenerate" action — see
  [deploy/amira/README.md](../deploy/amira/README.md#the-visualizations-volume).

### Memory ceilings are oversubscribed on purpose

On a small host the per-service `memory` limits deliberately sum to more than
the host has. They are ceilings for a bad moment, not allocations. On the
reference 3.8 GiB deployment:

Measured on the reference 3.8 GiB deployment. `anon` is the figure that
matters — anonymous pages cannot be reclaimed, so that is what actually has to
fit:

| service | ceiling | `anon` (real) | note |
|---|---|---|---|
| php | 1536M | ~21M idle | far higher during imports and thumbnailing |
| db | 1024M | ~563M | 512M InnoDB buffer pool plus overhead |
| typesense | 512M | ~363M | in-memory index for a ~10k-item corpus |
| amira-mcp | 512M | ~195M | measured 2026-11-20 (~129M on 11-13, ~83M in October); grows as the snapshot is re-crawled. At 384M it hit the ceiling 376 times and crashed with a JavaScript heap OOM; the heap is now capped at 384M (`AMIRA_MCP_HEAP_MB`). Set with `AMIRA_MCP_MEMORY_LIMIT` |
| web | 256M | ~10M | but its tmpfs can occupy ~130M of the same limit |
| sparql (AMIRA, opt-in) | 256M | ~7M | reaches its ceiling only on a runaway query, which its watchdog stops |
| amira-mcp-curator (AMIRA, opt-in) | 640M | ~260M | measured 2026-11-13 after the first keyed crawl, plus ~21M of cache tmpfs on the same limit; at 384M the crawl hit the ceiling, at 512M it crashed with a JavaScript heap OOM. Heap capped at 448M (`AMIRA_CURATOR_HEAP_MB`). Set with `AMIRA_CURATOR_MEMORY_LIMIT` |

Total ceilings ~3.8 GiB (~4.0 GiB with the opt-in SPARQL endpoint) against
~1.0 GiB of anonymous use. The curator endpoint adds ~260M of anonymous use
and a 640M ceiling; when it runs on the reference host, take the room from php
(`PHP_CONTAINER_MEMORY=1280M`; php was using ~178M of its 1408M when last
measured), which keeps the total at ~4.4 GiB. Nothing is wrong with that — but **raising one
service's ceiling meaningfully requires lowering another's**, and several
services peaking together can reach the OOM killer.

Measure with the cgroup counters, not `docker stats`:

```bash
cid=$(docker compose ps -q typesense)
docker exec "$cid" sh -c 'grep -E "^(anon|file) " /sys/fs/cgroup/memory.stat; \
    cat /sys/fs/cgroup/memory.peak'
```

Three traps:

- **`docker stats` MEM USAGE includes page cache.** A container read just after
  a recreate can report several times what the same container reports after
  days of uptime, because cache has since been reclaimed. Sizing a limit from
  that number gets it wrong in both directions — we briefly cut typesense to
  384M on a 69M reading, when its real `anon` is ~363M and the cut would have
  risked an OOM kill.
- **`memory.peak` often equals the ceiling exactly** for `db` and `typesense`.
  That is the startup page-cache spike filling the cgroup and then being
  reclaimed, not evidence of anonymous pressure. Compare `anon` before
  reacting.
- **A container's `tmpfs` mounts count against its own limit.** `web` looks
  idle at ~10M, but `/var/cache/nginx` and `/tmp` can legitimately grow to
  ~130M inside its 256M.

Typesense is the tightest service here (~363M anon in 512M). If the collection
grows substantially, raise `SEARCH_MEMORY_LIMIT` and take the headroom from
`php`, which is the most over-provisioned at idle — but only after measuring
`php` during a real import, which is when it actually needs the room.
