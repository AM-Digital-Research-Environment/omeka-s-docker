#!/usr/bin/env bash
# Render the web service's nginx templates exactly as Compose mounts them, run
# `nginx -t` on the result in a throwaway container from the nginx image the
# web target is built on, then send it real requests:
#
#   every variant  the access log carries no Omeka API key (key first, in the
#                  middle, alone, both, URL-encoded values, PHP's alternative
#                  spellings, repeated keys, in the referer, none at all);
#   every variant  static caching (long-lived only with Omeka's ?v=, a year
#                  for /application/asset/, a week for modules and themes;
#                  under /files/ only Omeka's media directories are
#                  long-lived), the sandbox CSP on HTML/SVG/XML uploads but
#                  not on images or PDF, the deny rules still answering under
#                  /files/, X-XSS-Protection: 0, and HSTS only when
#                  NGINX_HSTS_MAX_AGE > 0 on a request a trusted proxy marked
#                  HTTPS (in a second container with that set);
#   every variant  the /api rate limit: off by default (a burst to /api never
#                  answers 429); with NGINX_API_RATE_LIMIT=on and a tiny rate
#                  (a third container) /api and /api-local answer 429 past the
#                  burst while ordinary pages and /api-context do not, clients
#                  a trusted proxy names by X-Forwarded-For get their own
#                  budget, limited requests still reach index.php and keep the
#                  deny rules, and the access log stays redacted;
#   amira          with no curator service, /curator/mcp answers 502 and nginx
#                  still starts; with a stand-in upstream it proxies to /mcp
#                  with Authorization passed through, X-Forwarded-For
#                  overwritten and caching headers replaced by no-store; the
#                  reserved OAuth well-known path stays denied.
#
# No stack is started: three nginx containers, plus the stand-in for amira, on a
# throwaway network, all removed on exit. The Omeka, MCP and SPARQL upstreams
# are absent on purpose, which is also what proves nginx boots without them.
#
# Usage: .github/scripts/check-nginx.sh base|amira
# Needs what Compose needs to render the files: MYSQL_PASSWORD, plus
# SERVER_NAME for amira (the CI validate job sets both).

set -Eeuo pipefail

variant="${1:?usage: check-nginx.sh base|amira}"
case "$variant" in
    base) compose_files=(-f docker-compose.yml) ;;
    amira) compose_files=(-f docker-compose.yml -f compose.amira.yml) ;;
    *) echo "usage: check-nginx.sh base|amira" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/../.."

image="$(sed -nE 's/^FROM (nginx:[^[:space:]]+) AS web$/\1/p' Dockerfile)"
[[ -n "$image" ]] || { echo "ERROR: no 'FROM nginx:... AS web' stage in Dockerfile" >&2; exit 1; }

suffix="${GITHUB_RUN_ID:-$$}-${variant}"
network="nginx-check-${suffix}"
web="nginx-check-web-${suffix}"
web_hsts="nginx-check-web-hsts-${suffix}"
web_api="nginx-check-web-api-${suffix}"
stub="nginx-check-stub-${suffix}"
workdir="$(mktemp -d)"
failures=0

cleanup() {
    docker rm -f "$web" "$web_hsts" "$web_api" "$stub" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf -- "$workdir"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# docker run arguments reproducing the web service as Compose renders it: its
# bind mounts (the templates), environment (the envsubst values and filter),
# tmpfs mounts and capabilities. Named volumes (media, modules, the SPARQL
# socket) are left out; nginx -t does not open them.
# Rendered to a file first: a failure inside the process substitution below
# would not stop the script, which would then test nginx's default config.
docker compose -p nginx-check "${compose_files[@]}" config --format json > "$workdir/compose.json"
mapfile -d '' run_args < <(
    python3 -c '
import json, re, sys

web = json.load(sys.stdin)["services"]["web"]
args = ["--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges"]
for cap in web.get("cap_add", []):
    args += ["--cap-add", cap]
for mount in web.get("tmpfs", []):
    args += ["--tmpfs", mount]
for mount in web.get("volumes", []):
    if mount.get("type") == "bind":
        args += ["-v", mount["source"] + ":" + mount["target"] + (":ro" if mount.get("read_only") else "")]
env = web.get("environment", {})
env = dict(env.items() if isinstance(env, dict) else (str(e).partition("=")[::2] for e in env))
# nginx-http-settings.conf needs these rendered, or nginx reads the literal
# ${NAME} as an unknown variable (or an invalid rate) and refuses to start.
# Supply each one (at its Compose default) if this Compose file does not pass
# it yet, loudly, so the check still exercises the templates.
defaults = {"NGINX_HSTS_MAX_AGE": "0", "NGINX_API_RATE_LIMIT": "off", "NGINX_API_RATE": "10r/s"}
filt = env.get("NGINX_ENVSUBST_FILTER", "")
for name, default in defaults.items():
    if name not in env:
        sys.stderr.write(f"WARNING: the web service does not set {name}; using {default}\n")
        env[name] = default
    # Whole names: NGINX_API_RATE is a prefix of NGINX_API_RATE_LIMIT.
    if filt and not re.search(r"(?:^|[(|^])" + name + r"(?:[)|$]|$)", filt):
        sys.stderr.write(f"WARNING: NGINX_ENVSUBST_FILTER does not list {name}; adding it\n")
        # compose config keeps the escaped "$$" of the YAML; grep -E reads it as $.
        body = filt.rstrip("$")
        if filt.startswith("^(") and body.endswith(")"):
            filt = body[:-1] + "|" + name + ")$"
        else:
            filt = "(" + filt + ")|^" + name + "$"
if filt:
    env["NGINX_ENVSUBST_FILTER"] = filt
for key, value in env.items():
    args += ["-e", f"{key}={value}"]
sys.stdout.write("".join(arg + "\0" for arg in args))
' < "$workdir/compose.json"
)
[[ "${#run_args[@]}" -gt 0 ]] || { echo "ERROR: could not read the web service from Compose" >&2; exit 1; }

# A stand-in document root (in production the image's code layer plus the
# media, module and theme volumes), with one file per caching / content-type
# case the requests below probe. 0755/0644 so the nginx workers can read it.
docroot="$workdir/docroot"
storage_id=0123456789abcdef0123456789abcdef01234567
for path in \
    application/asset/css/style.css \
    modules/Probe/asset/js/probe.js \
    modules/Probe/asset/js/probe.mjs \
    themes/probe/asset/css/style.css \
    "files/original/$storage_id.jpg" \
    "files/original/$storage_id.svg" \
    "files/original/$storage_id.html" \
    "files/original/$storage_id.xml" \
    "files/original/$storage_id.pdf" \
    "files/large/$storage_id.jpg" \
    "files/asset/$storage_id.png" \
    files/probe-module/dump.nt.gz \
    files/probe-module/probe.jpg \
    files/probe.php \
    files/probe.sql \
    files/backup/theme.zip \
    files/iiif/3/1.manifest.json \
    files/.htaccess; do
    mkdir -p "$docroot/$(dirname "$path")"
    echo probe > "$docroot/$path"
done
chmod -R a+rX "$docroot"
run_args+=(-v "$docroot:/var/www/html:ro")

docker network create "$network" >/dev/null

echo "==> nginx -t ($variant, $image)"
docker run --rm --network "$network" "${run_args[@]}" "$image" nginx -t

echo "==> Starting nginx with every upstream absent"
docker run -d --name "$web" --network "$network" "${run_args[@]}" "$image" >/dev/null
for _ in $(seq 1 30); do
    if [[ "$(docker exec "$web" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/config/ 2>/dev/null)" == "404" ]]; then
        break
    fi
    sleep 1
done

# curl inside the nginx container: -g so [ ] in a URL are literal.
request() {
    docker exec "$web" curl -gsS -o /dev/null -w '%{http_code}' "$@" || true
}
# Same, in another container: request_in <container> <curl args...>.
request_in() {
    local container="$1"
    shift
    docker exec "$container" curl -gsS -o /dev/null -w '%{http_code}' "$@" || true
}

echo "==> Access log redaction"
# Each case: tag, path, expected request line in the log. The tag goes in the
# User-Agent so its line can be found again.
cases=(
    "keys-first|/api/items?key_identity=SECRETID1&key_credential=SECRETCRED1&page=2|GET /api/items?key_identity=[REDACTED]&key_credential=[REDACTED]&page=2 HTTP/1.1"
    "keys-middle|/api/items?page=2&key_identity=SECRETID2&per_page=50&key_credential=SECRETCRED2|GET /api/items?page=2&key_identity=[REDACTED]&per_page=50&key_credential=[REDACTED] HTTP/1.1"
    "one-key-last|/api/items?is_public=0&per_page=1&key_credential=SECRETCRED3|GET /api/items?is_public=0&per_page=1&key_credential=[REDACTED] HTTP/1.1"
    "encoded-values|/api/items?key_identity=SECRET%2BID4%3D&key_credential=SECRET%26CRED4%2F|GET /api/items?key_identity=[REDACTED]&key_credential=[REDACTED] HTTP/1.1"
    "php-spellings|/api/items?key%5Fidentity=SECRETID5&Key.Credential=SECRETCRED5|GET /api/items?key%5Fidentity=[REDACTED]&Key.Credential=[REDACTED] HTTP/1.1"
    "repeated-keys|/api/items?key_identity=SECRETID6&key_identity=SECRETID6B&key_credential=SECRETCRED6&page=1|GET /api/items?[REDACTED] HTTP/1.1"
    "empty-value|/api/items?key_identity=&page=1|GET /api/items?key_identity=&page=1 HTTP/1.1"
    "no-key|/api/items?page=3&sort_by=id&sort_order=asc|GET /api/items?page=3&sort_by=id&sort_order=asc HTTP/1.1"
)
for entry in "${cases[@]}"; do
    IFS='|' read -r tag path _ <<< "$entry"
    request -A "check-$tag" "http://127.0.0.1$path" >/dev/null
done
request -A "check-referer" -e "https://example.org/api/items?page=1&key_credential=SECRETCRED7" \
    "http://127.0.0.1/s/amira/page/about" >/dev/null
sleep 1

# The access log is nginx's stdout; stderr is the error log (see below).
access_log="$(docker logs "$web" 2>/dev/null)"
for entry in "${cases[@]}"; do
    IFS='|' read -r tag _ expected <<< "$entry"
    line="$(grep -F "\"check-$tag\"" <<< "$access_log" || true)"
    if [[ -z "$line" ]]; then
        fail "$tag: no access log line"
    elif ! grep -qF "\"$expected\"" <<< "$line"; then
        fail "$tag: expected \"$expected\", logged: $line"
    else
        echo "    ok  $tag"
    fi
done
line="$(grep -F '"check-referer"' <<< "$access_log" || true)"
if grep -qF '"GET /s/amira/page/about HTTP/1.1"' <<< "$line" \
    && grep -qF '"https://example.org/api/items?[REDACTED]"' <<< "$line"; then
    echo "    ok  referer"
else
    fail "referer: logged: ${line:-nothing}"
fi
if grep -q 'SECRET' <<< "$access_log"; then
    fail "a key value reached the access log:"
    grep 'SECRET' <<< "$access_log" >&2
fi
# Same field layout as the image's "main" format, so log tooling still parses it.
if ! grep -F '"check-no-key"' <<< "$access_log" \
    | grep -qE '^[0-9a-f.:]+ - - \[[^]]+\] "GET [^"]+" [0-9]{3} [0-9]+ "-" "check-no-key" "-"$'; then
    fail "the access log line no longer has the fields of nginx's main format"
fi

# Response headers of a GET, lower-cased names, CRs stripped. First argument:
# the container.
headers() {
    local container="$1"
    shift
    docker exec "$container" curl -gsS -o /dev/null -D - "$@" | tr -d '\r' \
        | sed -E 's/^([^:]+):/\L\1:/' || true
}

# expect_header <description> <headers> <grep -E pattern on a header line>
expect_header() {
    if grep -qE "$3" <<< "$2"; then echo "    ok  $1"; else fail "$1: no line matching '$3' in: $2"; fi
}
expect_no_header() {
    if grep -qE "$3" <<< "$2"; then fail "$1: unexpected line matching '$3' in: $2"; else echo "    ok  $1"; fi
}

long='^cache-control: public, max-age=31536000, immutable$'
week='^cache-control: public, max-age=604800$'
revalidate='^cache-control: public, max-age=0, must-revalidate$'
sandbox="^content-security-policy: sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:$"
frame='^content-security-policy: frame-ancestors '

echo "==> Static asset caching"
h="$(headers "$web" 'http://127.0.0.1/application/asset/css/style.css?v=4.2.1')"
expect_header "core asset with ?v= -> a year, immutable" "$h" "$long"
h="$(headers "$web" http://127.0.0.1/application/asset/css/style.css)"
expect_header "core asset without ?v= -> revalidate" "$h" "$revalidate"
expect_header "ETag kept" "$h" '^etag: '
expect_header "Last-Modified kept" "$h" '^last-modified: '
h="$(headers "$web" 'http://127.0.0.1/application/asset/css/style.css?v=')"
expect_header "core asset with empty ?v= -> revalidate" "$h" "$revalidate"
h="$(headers "$web" 'http://127.0.0.1/modules/Probe/asset/js/probe.js?v=1.0.0')"
expect_header "module asset with ?v= -> a week" "$h" "$week"
h="$(headers "$web" http://127.0.0.1/modules/Probe/asset/js/probe.js)"
expect_header "module asset without ?v= -> revalidate" "$h" "$revalidate"
h="$(headers "$web" 'http://127.0.0.1/themes/probe/asset/css/style.css?v=2.0')"
expect_header "theme asset with ?v= -> a week" "$h" "$week"
h="$(headers "$web" 'http://127.0.0.1/modules/Probe/asset/js/probe.mjs?v=1.0.0')"
expect_header ".mjs with ?v= -> a week" "$h" "$week"
expect_header ".mjs served as JavaScript" "$h" '^content-type: application/javascript'
h="$(headers "$web" http://127.0.0.1/modules/Probe/asset/js/probe.mjs)"
expect_header ".mjs without ?v= -> revalidate" "$h" "$revalidate"

echo "==> /files/"
h="$(headers "$web" "http://127.0.0.1/files/original/$storage_id.jpg")"
expect_header "original/ -> a year, immutable" "$h" "$long"
expect_header "original/ keeps the frame-ancestors CSP" "$h" "$frame"
expect_no_header "no sandbox CSP on a JPEG" "$h" '^content-security-policy: sandbox'
expect_header "security headers on /files/" "$h" '^x-content-type-options: nosniff$'
h="$(headers "$web" "http://127.0.0.1/files/asset/$storage_id.png")"
expect_header "asset/ -> a year, immutable" "$h" "$long"
h="$(headers "$web" "http://127.0.0.1/files/large/$storage_id.jpg")"
expect_header "large/ -> a week" "$h" "$week"
h="$(headers "$web" http://127.0.0.1/files/probe-module/dump.nt.gz)"
expect_header "other /files/ directory -> revalidate" "$h" "$revalidate"
h="$(headers "$web" 'http://127.0.0.1/files/probe-module/probe.jpg?v=1')"
expect_header "other /files/ directory, image with ?v= -> still revalidate" "$h" "$revalidate"
for ext in svg html xml; do
    h="$(headers "$web" "http://127.0.0.1/files/original/$storage_id.$ext")"
    expect_header "sandbox CSP on .$ext" "$h" "$sandbox"
    expect_header "frame-ancestors CSP still sent with .$ext" "$h" "$frame"
done
h="$(headers "$web" "http://127.0.0.1/files/original/$storage_id.pdf")"
expect_no_header "no sandbox CSP on a PDF" "$h" '^content-security-policy: sandbox'
h="$(headers "$web" "http://127.0.0.1/application/asset/css/style.css")"
expect_no_header "no sandbox CSP outside /files/" "$h" '^content-security-policy: sandbox'
for probe in "files/probe.php|404" "files/original/$storage_id.jpg.php|404" \
    "files/original/probe.php/x.jpg|404" "files/probe.sql|404" "files/.htaccess|403" \
    "files/backup/theme.zip|404" "files/iiif/3/1.manifest.json|404" "files/import/|404"; do
    IFS='|' read -r path expected <<< "$probe"
    code="$(request "http://127.0.0.1/$path")"
    [[ "$code" == "$expected" ]] && echo "    ok  /$path -> $expected" || fail "/$path -> $code, expected $expected"
done
# A missing file still goes to Omeka's router, absent here, hence 502.
code="$(request "http://127.0.0.1/files/original/missing.jpg")"
[[ "$code" == "502" ]] && echo "    ok  missing /files/ file -> index.php (502 without php)" \
    || fail "missing /files/ file -> $code, expected 502 from the index.php fallback"

echo "==> Security headers"
h="$(headers "$web" http://127.0.0.1/config/)"
expect_header "X-XSS-Protection: 0 (server level)" "$h" '^x-xss-protection: 0$'
h="$(headers "$web" http://127.0.0.1/application/asset/css/style.css)"
expect_header "X-XSS-Protection: 0 (snippet)" "$h" '^x-xss-protection: 0$'

echo "==> HSTS"
h="$(headers "$web" -H 'X-Forwarded-Proto: https' http://127.0.0.1/config/)"
expect_no_header "absent by default" "$h" '^strict-transport-security:'
# Second container: HSTS on, and the curl inside it (127.0.0.1) is the trusted
# proxy. The later -e wins over the value from Compose.
docker run -d --name "$web_hsts" --network "$network" "${run_args[@]}" \
    -e NGINX_HSTS_MAX_AGE=31536000 -e NGINX_TRUSTED_PROXY_CIDR=127.0.0.1/32 "$image" >/dev/null
for _ in $(seq 1 30); do
    if [[ "$(docker exec "$web_hsts" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/config/ 2>/dev/null)" == "404" ]]; then
        break
    fi
    sleep 1
done
hsts='^strict-transport-security: max-age=31536000$'
h="$(headers "$web_hsts" -H 'X-Forwarded-Proto: https' http://127.0.0.1/config/)"
expect_header "HTTPS via trusted proxy -> sent (server level)" "$h" "$hsts"
h="$(headers "$web_hsts" -H 'X-Forwarded-Proto: https' 'http://127.0.0.1/application/asset/css/style.css?v=1')"
expect_header "HTTPS via trusted proxy -> sent (snippet)" "$h" "$hsts"
h="$(headers "$web_hsts" -H 'X-Forwarded-Proto: https' "http://127.0.0.1/files/original/$storage_id.svg")"
expect_header "HTTPS via trusted proxy -> sent (/files/)" "$h" "$hsts"
h="$(headers "$web_hsts" -H 'X-Forwarded-Proto: https' http://127.0.0.1/s/probe/page/about)"
expect_header "HTTPS via trusted proxy -> sent (FastCGI location)" "$h" "$hsts"
h="$(headers "$web_hsts" http://127.0.0.1/config/)"
expect_no_header "plain HTTP -> absent" "$h" '^strict-transport-security:'
h="$(headers "$web_hsts" -H 'X-Forwarded-Proto: http' http://127.0.0.1/application/asset/css/style.css)"
expect_no_header "proxy said http -> absent (snippet)" "$h" '^strict-transport-security:'
docker rm -f "$web_hsts" >/dev/null

# wait_ready <container>: until nginx answers (the deny rule's 404).
wait_ready() {
    for _ in $(seq 1 30); do
        if [[ "$(docker exec "$1" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/config/ 2>/dev/null)" == "404" ]]; then
            return 0
        fi
        sleep 1
    done
}

# burst_codes <container> <count> <curl args...>: the status codes of <count>
# back-to-back requests, one per line, from one curl process (so the burst is
# really back to back).
burst_codes() {
    local container="$1" count="$2"
    shift 2
    local urls=()
    for _ in $(seq 1 "$count"); do urls+=("$@"); done
    docker exec "$container" curl -gsS -o /dev/null -w '%{http_code}\n' "${urls[@]}" || true
}

echo "==> /api rate limit"
codes="$(burst_codes "$web" 40 http://127.0.0.1/api/items)"
if grep -q '^429$' <<< "$codes"; then
    fail "default (off): a burst to /api answered 429: $(sort <<< "$codes" | uniq -c | tr '\n' ' ')"
else
    echo "    ok  off by default: 40 requests to /api, no 429"
fi
# Third container: limit on at one request a minute, so everything past the
# burst of 20 (plus the first request) is refused; the curl inside it
# (127.0.0.1) is the trusted proxy so X-Forwarded-For can name other clients.
docker run -d --name "$web_api" --network "$network" "${run_args[@]}" \
    -e NGINX_API_RATE_LIMIT=on -e NGINX_API_RATE=1r/m -e NGINX_TRUSTED_PROXY_CIDR=127.0.0.1/32 \
    "$image" >/dev/null
wait_ready "$web_api"
codes="$(burst_codes "$web_api" 30 -A check-api-burst 'http://127.0.0.1/api/items?key_identity=SECRETAPIID&key_credential=SECRETAPICRED')"
passed="$(grep -c '^502$' <<< "$codes" || true)"
limited="$(grep -c '^429$' <<< "$codes" || true)"
if [[ "$passed" == "21" && "$limited" == "9" ]]; then
    echo "    ok  on: burst of 20 + 1 reached index.php (502 without php), the other 9 -> 429"
else
    fail "on: expected 21 x 502 then 9 x 429 for /api/items, got: $(sort <<< "$codes" | uniq -c | tr '\n' ' ')"
fi
for path in /api /api/ /api/items/1 /api-local /api-local/resource_templates/1 /api/items/1.css; do
    code="$(request_in "$web_api" "http://127.0.0.1$path")"
    [[ "$code" == "429" ]] && echo "    ok  $path -> 429 once the budget is spent" \
        || fail "$path -> $code, expected 429 once the budget is spent"
done
for probe in "/s/probe/page/about|502" "/api-context|502" "/apix|502" \
    "/admin/login|502" "/application/asset/css/style.css|200"; do
    IFS='|' read -r path expected <<< "$probe"
    code="$(request_in "$web_api" "http://127.0.0.1$path")"
    [[ "$code" == "$expected" ]] && echo "    ok  $path not limited ($code)" \
        || fail "$path -> $code, expected $expected (not rate-limited)"
done
# Deny rules keep winning over the API location.
for probe in "/api/.env|403" "/api/x.php|404" "/api/dump.sql|404"; do
    IFS='|' read -r path expected <<< "$probe"
    code="$(request_in "$web_api" "http://127.0.0.1$path")"
    [[ "$code" == "$expected" ]] && echo "    ok  $path -> $expected (deny rule first)" \
        || fail "$path -> $code, expected $expected"
done
# Keyed on the real client: another visitor behind the trusted proxy has a
# full budget.
code="$(request_in "$web_api" -H 'X-Forwarded-For: 203.0.113.7' http://127.0.0.1/api/items)"
[[ "$code" == "502" ]] && echo "    ok  another client (X-Forwarded-For via trusted proxy) not limited" \
    || fail "another client behind the trusted proxy -> $code, expected 502 (own budget)"
sleep 1
api_log="$(docker logs "$web_api" 2>/dev/null)"
if grep -q 'SECRET' <<< "$api_log"; then
    fail "a key value reached the access log of rate-limited requests"
elif grep -F '"check-api-burst"' <<< "$api_log" | grep -qE '" 429 [0-9]+ '; then
    echo "    ok  429s logged, keys redacted"
else
    fail "no redacted 429 line for the burst in the access log"
fi
docker rm -f "$web_api" >/dev/null

if [[ "$variant" == "amira" ]]; then
    echo "==> /curator/mcp with no curator service"
    code="$(request -X POST -H 'Authorization: Bearer check-token' http://127.0.0.1/curator/mcp)"
    [[ "$code" == "502" ]] && echo "    ok  POST /curator/mcp -> 502" || fail "POST /curator/mcp -> $code, expected 502"
    code="$(request http://127.0.0.1/mcp)"
    [[ "$code" == "502" ]] && echo "    ok  GET /mcp -> 502" || fail "GET /mcp -> $code, expected 502"
    # Reserved for the OAuth step; until it is routed the dot-path deny answers.
    code="$(request http://127.0.0.1/.well-known/oauth-protected-resource/curator/mcp)"
    [[ "$code" == "403" ]] && echo "    ok  OAuth metadata path -> 403 (not routed yet)" \
        || fail "/.well-known/oauth-protected-resource/curator/mcp -> $code, expected 403"

    echo "==> /curator/mcp with a stand-in curator service"
    printf '%s\n' \
        'server {' \
        '    listen 8787;' \
        '    location / {' \
        '        default_type text/plain;' \
        '        add_header Cache-Control "public, max-age=600" always;' \
        '        return 200 "uri=$request_uri auth=$http_authorization xff=$http_x_forwarded_for\n";' \
        '    }' \
        '}' > "$workdir/stub.conf"
    docker run -d --name "$stub" --network "$network" --network-alias amira-mcp-curator \
        -v "$workdir/stub.conf:/etc/nginx/conf.d/default.conf:ro" "$image" >/dev/null
    # The web nginx caches the earlier "not found" answer for valid=10s.
    sleep 11
    response="$(docker exec "$web" curl -gsS -D - -X POST \
        -H 'Authorization: Bearer check-token' -H 'X-Forwarded-For: 203.0.113.9' \
        -H 'Content-Type: application/json' --data '{}' \
        'http://127.0.0.1/curator/mcp?probe=1' || true)"
    grep -q '^HTTP/1.1 200' <<< "$response" && echo "    ok  proxied (200)" || fail "not proxied: $response"
    grep -qF 'uri=/mcp?probe=1 ' <<< "$response" && echo "    ok  path rewritten to /mcp, query kept" \
        || fail "upstream did not see /mcp?probe=1: $response"
    grep -qF 'auth=Bearer check-token ' <<< "$response" && echo "    ok  Authorization passed through" \
        || fail "Authorization did not reach the upstream: $response"
    grep -qE 'xff=127\.0\.0\.1$' <<< "$response" && echo "    ok  X-Forwarded-For overwritten" \
        || fail "X-Forwarded-For was not overwritten with the client address: $response"
    if grep -qi '^cache-control: no-store' <<< "$response" && ! grep -qi 'max-age=600' <<< "$response"; then
        echo "    ok  Cache-Control: no-store"
    else
        fail "upstream caching headers were not replaced by no-store: $response"
    fi
    grep -qi '^x-content-type-options: nosniff' <<< "$response" && echo "    ok  security headers restated" \
        || fail "the location's add_header dropped the server-level security headers: $response"
    # Exact match only: nothing below /curator/mcp (such as the server's
    # token-protected /metrics) is reachable through it.
    body="$(docker exec "$web" curl -gsS http://127.0.0.1/curator/mcp/metrics || true)"
    grep -qF 'uri=' <<< "$body" && fail "/curator/mcp/metrics reached the curator service" \
        || echo "    ok  /curator/mcp/metrics not proxied"
fi

if (( failures > 0 )); then
    echo "nginx check failed ($variant): $failures failure(s)." >&2
    echo "--- nginx output ---" >&2
    docker logs "$web" >&2 || true
    exit 1
fi
echo "nginx check passed ($variant)."
