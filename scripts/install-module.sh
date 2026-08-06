#!/usr/bin/env bash
# Add a module to the operator manifest, then rebuild immutable code images.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/install-module.sh <Omeka-CLI-module-URI> [tag|branch|commit]
       scripts/install-module.sh list

Examples:
  scripts/install-module.sh CSVImport
  scripts/install-module.sh https://github.com/owner/repo/releases/download/v1.2.3/Module.zip
  scripts/install-module.sh gh:owner/repository v1.2.3
  scripts/install-module.sh gh:owner/repository 0123456789abcdef

The URI syntax is documented by GhentCDH/Omeka-S-Cli. Where a project publishes
a release archive, its URL is the best choice: it installs the packaged module,
while a gh: URI clones the repository with its development tree and history.
Otherwise prefer a release tag or full commit SHA. Either way the module is
baked into both PHP and nginx images; no live container files are modified.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."
manifest="_docker/extra-modules.txt"

[[ ${1:-} == list ]] && { grep -Ev '^[[:space:]]*(#|$)' "$manifest" || true; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

uri="$1"
ref="${2:-}"
[[ "$uri" != *$'\n'* && "$uri" != *$'\r'* && "$uri" != \#* && "$uri" != *','* && "$uri" != *' '* ]] \
    || { echo "Invalid module URI: $uri" >&2; exit 2; }
if [[ -n "$ref" ]]; then
    # A release archive is already a fixed version, and omeka-s-cli only
    # recognises a zip URL when nothing follows the .zip.
    [[ "$uri" != *.zip ]] || { echo "A release archive URL takes no ref." >&2; exit 2; }
    [[ "$uri" != *'#'* ]] || { echo "URI already includes a ref." >&2; exit 2; }
    [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Invalid module ref: $ref" >&2; exit 2; }
    uri="${uri}#${ref}"
fi

if grep -Fxq "$uri" "$manifest"; then
    echo "Module already present in $manifest: $uri"
else
    printf '%s\n' "$uri" >> "$manifest"
    echo "Added module to $manifest: $uri"
fi

exec bash scripts/rebuild-code.sh
