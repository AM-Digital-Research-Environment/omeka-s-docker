# AMIRA MCP — host nginx configuration

The `amira-mcp` service (in [`compose.amira.yml`](../../compose.amira.yml)) and the
container's `/mcp` rule (in [`nginx-mcp-location.conf`](nginx-mcp-location.conf)) are both
version-controlled here. The **host** nginx that terminates TLS is **not** — it lives at
`/etc/nginx/` and is root-owned. These are the changes it needs so that
`https://data.africamultiple.uni-bayreuth.de/mcp` reaches the MCP server with working SSE.

Why a dedicated block: the host `location /` proxies to the compose nginx on `:8080` with
default `proxy_buffering on`, which would break Streamable-HTTP/SSE. We add a `/mcp` block
with buffering off and a long read timeout, and a per-client rate limit (the host sees the
real `$remote_addr`, unlike the compose nginx behind Docker's bridge).

## 1. Rate-limit zone (http context)

Create `/etc/nginx/conf.d/mcp-ratelimit.conf`:

```nginx
# Per-client rate limit for the public, unauthenticated /mcp endpoint.
limit_req_zone $binary_remote_addr zone=mcp:10m rate=60r/m;
```

## 2. `/mcp` location (in the `listen 443` server block)

In `/etc/nginx/sites-enabled/data.africamultiple.conf`, add this **before** `location /`:

```nginx
    # AMIRA MCP server (Streamable-HTTP/SSE) — pass through to the compose nginx
    # un-buffered so SSE streams flow; rate-limited per real client IP.
    location /mcp {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection        "";
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        limit_req zone=mcp burst=20 nodelay;
    }
```

## 3. Apply

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Host nginx is a normal install, so `reload` is safe (unlike the compose nginx, whose config
is an envsubst template applied via `docker compose restart web`).

## 4. Verify externally

```bash
curl -s -X POST https://data.africamultiple.uni-bayreuth.de/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

Expect a streamed `event: message` / `data: {...}` `initialize` result, reporting the
`amira-mcp-server` version currently deployed — not an Omeka HTML page or a 404.
