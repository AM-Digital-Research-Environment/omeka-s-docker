#!/usr/bin/env bash
# One safe entry point for updating configured modules and themes everywhere.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/update-extensions.sh [--dry-run] [--no-backup] [--pull]

Updates module/theme release pins, rebuilds the matching PHP and nginx images,
and, when the active Compose stack uses extension volumes, updates those live
volumes too. Pending module database migrations are applied at the end.

  --dry-run    Check pinned GitHub releases; change nothing.
  --no-backup  Skip the normal database/media/extension backup.
  --pull       Refresh Dockerfile base images while rebuilding.
EOF
}

dry_run=false
backup=true
rebuild_args=()
while (($#)); do
    case "$1" in
        --dry-run) dry_run=true ;;
        --no-backup) backup=false ;;
        --pull) rebuild_args+=(--pull) ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

if [[ "$dry_run" == true ]]; then
    exec bash scripts/update-module.sh --dry-run
fi

if [[ "$backup" == true ]]; then
    echo "Backing up before extension updates..."
    bash scripts/backup.sh
fi

# This updates every pinned release manifest and refreshes branch-based image
# downloads. It also rebuilds/restarts the application images.
bash scripts/update-module.sh "${rebuild_args[@]}"

# In the default layout, persistent volumes shadow modules/themes in the rebuilt
# image. Detect that layout and update the live copies as part of the same job.
if ! docker compose config --format json 2>/dev/null | python3 -c '
import json, sys
config = json.load(sys.stdin)
mounts = config["services"]["php"].get("volumes", [])
sys.exit(0 if any(
    isinstance(m, dict) and m.get("target") == "/var/www/html/modules"
    for m in mounts
) else 1)
'; then
    echo "Extension code is image-managed; no live volume sync is needed."
    exit 0
fi

echo "Updating registry-backed live modules..."
docker compose exec -T php omeka-s-cli module:update \
    --all --upgrade --base-path /var/www/html

read_module_manifest() {
    local manifest="$1" line uri
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -n "$line" && "$line" != \#* ]] || continue
        uri="${line%%[[:space:]]*}"
        case "$uri" in
            gh:*|http://*|https://*|git://*)
                echo "Refreshing live module: $uri"
                docker compose exec -T php omeka-s-cli module:download \
                    --force --upgrade --base-path /var/www/html "$uri"
                ;;
        esac
    done < "$manifest"
}

for manifest in _docker/default-modules.txt _docker/extra-modules.txt \
    deploy/*/modules.txt; do
    [[ -f "$manifest" ]] && read_module_manifest "$manifest"
done

read_theme_manifest() {
    local manifest="$1" line uri target before after created old
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -n "$line" && "$line" != \#* ]] || continue
        read -r uri target _ <<< "$line"
        before="$(docker compose exec -T php sh -c \
            'find /var/www/html/themes -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort')"
        echo "Refreshing live theme: $uri${target:+ -> $target}"
        docker compose exec -T php omeka-s-cli theme:download \
            --force --base-path /var/www/html "$uri"
        [[ -n "${target:-}" ]] || continue
        after="$(docker compose exec -T php sh -c \
            'find /var/www/html/themes -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort')"
        created="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
        [[ -n "$created" && "$created" != *$'\n'* ]] || {
            echo "Could not identify the downloaded directory for $uri" >&2
            return 1
        }
        [[ "$created" != "$target" ]] || continue
        old="/tmp/${target}.before-extension-update"
        docker compose exec -T php sh -c '
            set -eu
            source=$1 target=$2 old=$3
            test -d "/var/www/html/themes/$source"
            test ! -e "$old"
            if test -d "/var/www/html/themes/$target"; then
                mv "/var/www/html/themes/$target" "$old"
            fi
            mv "/var/www/html/themes/$source" "/var/www/html/themes/$target"
        ' sh "$created" "$target" "$old"
    done < "$manifest"
}

for manifest in _docker/extra-themes.txt deploy/*/themes.txt; do
    [[ -f "$manifest" ]] && read_theme_manifest "$manifest"
done

# A module can already contain newer code before this command starts (for
# example after an interrupted prior run), so apply every remaining migration.
while IFS= read -r module_id; do
    [[ -n "$module_id" ]] || continue
    echo "Applying pending module migration: $module_id"
    docker compose exec -T php omeka-s-cli module:upgrade \
        --base-path /var/www/html "$module_id"
done < <(docker compose exec -T php omeka-s-cli module:list \
    --base-path /var/www/html | awk -F '|' '$4 ~ /needs_upgrade/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2
    }')

echo "Extension update complete."
docker compose exec -T php omeka-s-cli module:list --base-path /var/www/html
docker compose exec -T php omeka-s-cli theme:list --base-path /var/www/html
