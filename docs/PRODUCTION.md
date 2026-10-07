# Production deployment

A walk-through for taking this Omeka S stack from a local install to a publicly reachable, TLS-terminated, hardened site. The README has snippets for [Caddy](../README.md#caddy-easiest-certificates-handled-for-you), [Traefik](../README.md#traefik-docker-native), and [standalone nginx](../README.md#standalone-nginx-reverse-proxy) reverse proxies — this guide expands on the standalone-nginx path with everything around it (firewall, cert provisioning, host hardening, verification).

If you use Caddy or Traefik instead, only sections **2** and **6** (and onward) are still relevant — the proxies handle TLS and HTTPS redirect themselves.

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

Write `/etc/nginx/sites-available/yoursite.conf` using [the example in the README](../README.md#standalone-nginx-reverse-proxy). Key points:

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
```

You should see:
- `HTTP/2 200` and a `strict-transport-security` header (if HSTS is enabled).
- An issuer string for a real CA, validity dates a few months in the future, and the SAN matching your hostname.
- A `301` redirect from HTTP to HTTPS.
- Only `https://` URLs in the rendered HTML.

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
- **AMIRA only:** the visualizations volume masks the module's shipped static
  inputs after its first population. If a DreVisualizations release changes
  those inputs, delete the volume and regenerate rather than rebuilding alone —
  see [deploy/amira/README.md](../deploy/amira/README.md).

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
| amira-mcp | 384M | ~83M | grows as the snapshot is re-crawled |
| web | 256M | ~10M | but its tmpfs can occupy ~130M of the same limit |

Total ceilings ~3.7 GiB against ~1.0 GiB of anonymous use. Nothing is wrong
with that — but **raising one service's ceiling meaningfully requires lowering
another's**, and several services peaking together can reach the OOM killer.

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
