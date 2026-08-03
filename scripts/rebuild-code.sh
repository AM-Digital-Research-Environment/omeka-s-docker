#!/usr/bin/env bash
# Rebuild and deploy the matching immutable PHP/nginx code images.

set -Eeuo pipefail

refresh=false
pull=false
start=true

usage() {
    cat <<'EOF'
Usage: scripts/rebuild-code.sh [--refresh] [--pull] [--no-start]

  --refresh   Invalidate module/theme download layers (for floating refs).
  --pull      Refresh Dockerfile base images before building.
  --no-start  Build both images without replacing running containers.
EOF
}

while (($#)); do
    case "$1" in
        --refresh) refresh=true ;;
        --pull) pull=true ;;
        --no-start) start=false ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
docker compose version >/dev/null

if [[ "$refresh" == true ]]; then
    OMEKA_ASSET_REFRESH="$(date -u +%Y%m%dT%H%M%SZ)"
    export OMEKA_ASSET_REFRESH
fi

build_args=()
[[ "$pull" == true ]] && build_args+=(--pull)

echo "Building matching PHP and nginx images..."
docker compose build "${build_args[@]}" php web

if [[ "$start" != true ]]; then
    echo "Images built. Running services were not changed."
    exit 0
fi

echo "Replacing application containers while preserving database and media volumes..."
docker compose up -d php web

deadline=$((SECONDS + 600))
for service in php web; do
    while :; do
        container_id="$(docker compose ps -q "$service")"
        status="$(docker inspect -f '{{.State.Health.Status}}' "$container_id" 2>/dev/null || echo unknown)"
        [[ "$status" == healthy ]] && break
        if ((SECONDS > deadline)); then
            echo "Timed out waiting for $service (last status: $status)." >&2
            docker compose ps >&2 || true
            exit 1
        fi
        sleep 5
    done
    echo "  $service: healthy"
done

echo "Immutable code deployment complete. Database and media volumes were retained."
