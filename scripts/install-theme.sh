#!/usr/bin/env bash
# Add a theme to the operator manifest, then rebuild immutable code images.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/install-theme.sh <Omeka-CLI-theme-URI> [tag|branch|commit]
       scripts/install-theme.sh list

Examples:
  scripts/install-theme.sh https://github.com/owner/repo/releases/download/v1.8.0/Theme.zip
  scripts/install-theme.sh gh:omeka-s-themes/CenterRow v1.8.0
  scripts/install-theme.sh gh:owner/repository 0123456789abcdef

Where a project publishes a release archive, its URL is the best choice: it
installs the packaged theme, while a gh: URI clones the repository with its
development tree and history. Otherwise prefer a release tag or full commit SHA.
Either way the theme is baked into both PHP and nginx images; no live container
files are modified.

A theme that must land in a particular folder needs a second field on its
manifest line ("<uri> <target-directory>"); add that by editing
_docker/extra-themes.txt directly. See deploy/amira/themes.txt for a worked
example.
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
    # A release archive is already a fixed version, and omeka-s-cli only
    # recognises a zip URL when nothing follows the .zip.
    [[ "$uri" != *.zip ]] || { echo "A release archive URL takes no ref." >&2; exit 2; }
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
