#!/usr/bin/env bash
# Pin and deploy an AMIRA MCP release without touching Omeka state.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: deploy/amira/update-amira-mcp.sh [latest|vX.Y.Z] [--refresh-data] [--dry-run]

The release tag is stored as AMIRA_MCP_VERSION in .env. --refresh-data forces
the same release to rebuild its bundled public-data snapshot without cache.
EOF
}

version=latest
refresh_data=false
dry_run=false
for arg in "$@"; do
    case "$arg" in
        latest|v[0-9]*) version="$arg" ;;
        --refresh-data) refresh_data=true ;;
        --dry-run) dry_run=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/../.."
[[ -f .env ]] || { echo ".env is required." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }

api="https://api.github.com/repos/AM-Digital-Research-Environment/amira-mcp-server"
if [[ "$version" == latest ]]; then
    version="$(curl -fsSL "$api/releases/latest" \
        | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' \
        | head -n 1)"
fi
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "Invalid AMIRA MCP release tag: $version" >&2; exit 1; }
curl -fsSL "$api/releases/tags/$version" >/dev/null \
    || { echo "Published release not found: $version" >&2; exit 1; }

current="$(sed -nE 's/^AMIRA_MCP_VERSION=(.*)$/\1/p' .env | tail -n 1)"
if [[ -z "$current" ]]; then
    # Never restate the version here: compose.amira.yml holds the single
    # authoritative default, and .env only overrides it.
    current="$(sed -nE 's/.*amira-mcp-server\.git#\$\{AMIRA_MCP_VERSION:-([^}]+)\}.*/\1/p' \
        compose.amira.yml | head -n 1)"
fi
current="${current:-unknown}"
echo "AMIRA MCP: $current -> $version"
if [[ "$dry_run" == true ]]; then
    echo "Would update .env, build the tagged release, and recreate only amira-mcp."
    exit 0
fi

original_env="$(mktemp)"
new_env="$(mktemp)"
trap 'rm -f -- "$original_env" "$new_env"' EXIT
cp .env "$original_env"
awk -v version="$version" '
    BEGIN { replaced = 0 }
    /^AMIRA_MCP_VERSION=/ { print "AMIRA_MCP_VERSION=" version; replaced = 1; next }
    { print }
    END { if (!replaced) print "AMIRA_MCP_VERSION=" version }
' .env > "$new_env"
mv "$new_env" .env

build_args=(--pull)
[[ "$refresh_data" == true ]] && build_args+=(--no-cache)
if ! docker compose build "${build_args[@]}" amira-mcp; then
    cp "$original_env" .env
    echo "Build failed; restored the previous .env." >&2
    exit 1
fi

docker compose up -d amira-mcp
container_id="$(docker compose ps -q amira-mcp)"
for _ in $(seq 1 60); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$container_id" 2>/dev/null || echo unknown)"
    [[ "$status" == healthy ]] && break
    sleep 2
done
[[ "${status:-unknown}" == healthy ]] \
    || { docker compose logs --tail 100 amira-mcp >&2; echo "amira-mcp is not healthy." >&2; exit 1; }

echo "AMIRA MCP $version is healthy."
