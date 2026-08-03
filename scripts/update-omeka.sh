#!/usr/bin/env bash
# Update the Omeka core build pin, back up state, and rebuild immutable images.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/update-omeka.sh [version|latest] [--dry-run]

The update changes OMEKA_VERSION in .env and rebuilds both PHP and nginx.
Database and media are backed up first. Applying Omeka's database migration is
a separate, deliberate admin action because an image rollback cannot reverse it.
EOF
}

version=latest
dry_run=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        -h|--help) usage; exit 0 ;;
        latest|v[0-9]*|[0-9]*) version="$arg" ;;
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."
[[ -f .env ]] || { echo ".env is required; copy .env.example first." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

if [[ "$version" == latest ]]; then
    version="$(curl -fsSL https://api.github.com/repos/omeka/omeka-s/releases/latest \
        | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([0-9][^"]*)".*/\1/p' \
        | head -n 1)"
fi
version="${version#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] \
    || { echo "Invalid Omeka version: $version" >&2; exit 1; }

release_url="https://github.com/omeka/omeka-s/releases/download/v${version}/omeka-s-${version}.zip"
curl -fsIL "$release_url" >/dev/null \
    || { echo "Omeka release archive not found: $release_url" >&2; exit 1; }

current="$(sed -nE 's/^[[:space:]]*OMEKA_VERSION=(.*)$/\1/p' .env | tail -n 1)"
current="${current:-4.2.1}"
echo "Omeka S: $current -> $version"
if [[ "$dry_run" == true ]]; then
    echo "Would back up persistent state, update .env, then rebuild PHP and nginx."
    exit 0
fi
[[ "$current" != "$version" ]] || { echo "Already at $version."; exit 0; }

backup_dir="backups/pre-omeka-${version}-$(date -u +%Y%m%dT%H%M%SZ)"
bash scripts/backup.sh "$backup_dir"

original_env="$(mktemp)"
new_env="$(mktemp)"
trap 'rm -f -- "$original_env" "$new_env"' EXIT
cp .env "$original_env"
awk -v version="$version" '
    BEGIN { replaced = 0 }
    /^OMEKA_VERSION=/ { print "OMEKA_VERSION=" version; replaced = 1; next }
    { print }
    END { if (!replaced) print "OMEKA_VERSION=" version }
' .env > "$new_env"
mv "$new_env" .env

if ! bash scripts/rebuild-code.sh; then
    cp "$original_env" .env
    echo "Build/deploy failed; restored the previous .env. Existing containers were retained." >&2
    exit 1
fi

echo "Core image updated. Backup: $backup_dir"
echo "Review the Omeka admin upgrade prompt before applying database migrations."
