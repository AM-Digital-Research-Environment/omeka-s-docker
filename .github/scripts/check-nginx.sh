#!/usr/bin/env bash
# Render the web service's nginx templates exactly as Compose mounts them, run
# `nginx -t` on the result in a throwaway container from the nginx image the
# web target is built on, then send it real requests:
#
#   every variant  the access log carries no Omeka API key (key first, in the
#                  middle, alone, both, URL-encoded values, PHP's alternative
#                  spellings, repeated keys, in the referer, none at all);
#   amira          with no curator service, /curator/mcp answers 502 and nginx
#                  still starts; with a stand-in upstream it proxies to /mcp
#                  with Authorization passed through, X-Forwarded-For
#                  overwritten and caching headers replaced by no-store; the
#                  reserved OAuth well-known path stays denied.
#
# No stack is started: one nginx container, plus the stand-in for amira, on a
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
stub="nginx-check-stub-${suffix}"
workdir="$(mktemp -d)"
failures=0

cleanup() {
    docker rm -f "$web" "$stub" >/dev/null 2>&1 || true
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
mapfile -d '' run_args < <(
    docker compose -p nginx-check "${compose_files[@]}" config --format json | python3 -c '
import json, sys

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
pairs = env.items() if isinstance(env, dict) else (str(e).partition("=")[::2] for e in env)
for key, value in pairs:
    args += ["-e", f"{key}={value}"]
sys.stdout.write("".join(arg + "\0" for arg in args))
'
)

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
