#!/usr/bin/env bash
# Refresh floating module/theme refs in the immutable image build.

set -Eeuo pipefail

cat <<'EOF'
Refreshing all module and theme download layers.

For a deterministic update, edit the tag/commit after `#` in
_docker/extra-modules.txt or _docker/extra-themes.txt first. Floating branch
refs are supported, but make rollback and provenance weaker.
EOF

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."
exec bash scripts/rebuild-code.sh --refresh "$@"
