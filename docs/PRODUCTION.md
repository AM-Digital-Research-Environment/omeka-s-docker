# Production deployment

A walk-through for taking this Omeka S stack from a local install to a publicly reachable, TLS-terminated, hardened site. The README has snippets for [Caddy](../README.md#caddy-automatic-https), [Traefik](../README.md#traefik-docker-native), and [standalone nginx](../README.md#standalone-nginx-reverse-proxy) reverse proxies — this guide expands on the standalone-nginx path with everything around it (firewall, cert provisioning, host hardening, verification).

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
              │  container     │   nginx 1.28 (from this template)
              │  nginx         │
              └─────┬──────────┘
                    │ FastCGI
                    ▼
                php-fpm  ─→  mysql
                (container)   (container)
```

The host nginx terminates TLS and forwards `X-Forwarded-Proto: https` to the container; the container nginx maps that to PHP-FPM's `HTTPS=on` so Omeka generates correct `https://` URLs in IIIF manifests, emails, and redirects.

## 2. Free port 80 on the host

By default, the container binds the host's port 80. Move it to 8080 so the host nginx can take 80/443:

```bash
# In .env
NGINX_PORT=8080
```

```bash
docker compose up -d --force-recreate web
ss -tlnp | grep -E '127\.0\.0\.1:(80|8080)'   # expect only :8080
```

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
0 3 * * * <user> cd /path/to/omeka-s-docker && bash scripts/backup.sh \
    && find backups/ -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
```

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
