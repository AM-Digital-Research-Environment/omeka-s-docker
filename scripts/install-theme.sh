#!/usr/bin/env bash
# Add a theme to the operator manifest, then rebuild immutable code images.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/install-theme.sh <Omeka-CLI-theme-URI> [tag|branch|commit]
       scripts/install-theme.sh list

Examples:
  scripts/install-theme.sh gh:omeka-s-themes/CenterRow v1.8.0
  scripts/install-theme.sh gh:owner/repository 0123456789abcdef

Prefer a release tag or full commit SHA. The theme is baked into both PHP and
nginx images; no live container files are modified.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."
manifest="_docker/extra-themes.txt"

[[ ${1:-} == list ]] && { grep -Ev '^[[:space:]]*(#|$)' "$manifest" || true; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

uri="$1"
ref="${2:-}"
[[ "$uri" != *$'\n'* && "$uri" != *$'\r'* && "$uri" != \#* && "$uri" != *','* && "$uri" != *' '* ]] \
    || { echo "Invalid theme URI: $uri" >&2; exit 2; }
if [[ -n "$ref" ]]; then
    [[ "$uri" != *'#'* ]] || { echo "URI already includes a ref." >&2; exit 2; }
    [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Invalid theme ref: $ref" >&2; exit 2; }
    uri="${uri}#${ref}"
fi

if grep -Fxq "$uri" "$manifest"; then
    echo "Theme already present in $manifest: $uri"
else
    printf '%s\n' "$uri" >> "$manifest"
    echo "Added theme to $manifest: $uri"
fi

exec bash scripts/rebuild-code.sh
