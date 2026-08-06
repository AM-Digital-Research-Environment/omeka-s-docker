#!/usr/bin/env bash
# Move pinned release archives to the newest release, then rebuild code images.

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/update-module.sh [--dry-run] [rebuild options]

Rewrites the tag in every pinned GitHub release archive found in the module and
theme manifests to that repository's newest release, then rebuilds both images
with the download layers invalidated, so lines tracking a branch are re-fetched
as well.

  --dry-run   Report what would change; write nothing and rebuild nothing.

Any other option is passed to scripts/rebuild-code.sh (--pull, --no-start).

Manifests read: _docker/extra-modules.txt, _docker/extra-themes.txt, and every
deploy/*/modules.txt and deploy/*/themes.txt.

Set GH_TOKEN or GITHUB_TOKEN to lift GitHub's anonymous API rate limit.
EOF
}

dry_run=false
rebuild_args=()
while (($#)); do
    case "$1" in
        --dry-run) dry_run=true ;;
        -h|--help) usage; exit 0 ;;
        *) rebuild_args+=("$1") ;;
    esac
    shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

auth_header=()
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -z "$token" ]] || auth_header=(-H "Authorization: Bearer $token")

# The asset URL is fetched anonymously on purpose: GitHub rejects a request that
# carries both an Authorization header and the signed redirect it answers with,
# and the build downloads these archives without credentials anyway.
latest_release_tag() {
    curl -fsSL "${auth_header[@]}" \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$1/releases/latest" </dev/null \
        | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
        | head -n 1
}

asset_exists() {
    curl -fsIL -o /dev/null "$1" </dev/null
}

# "<url> [target-directory]", where the URL is a release asset:
#   https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>.zip
release_line='^(https://github\.com/([^/[:space:]]+/[^/[:space:]]+)/releases/download/)([^/[:space:]]+)/([^[:space:]]+\.zip)([[:space:]]+.*)?$'

manifests=()
for candidate in _docker/extra-modules.txt _docker/extra-themes.txt \
    deploy/*/modules.txt deploy/*/themes.txt; do
    [[ -f "$candidate" ]] && manifests+=("$candidate")
done

tmp=""
trap 'rm -f -- "$tmp"' EXIT

pinned=0
bumped=0
failed=0

for manifest in "${manifests[@]}"; do
    tmp="$(mktemp)"
    manifest_changed=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ ! "$line" =~ $release_line ]]; then
            printf '%s\n' "$line" >>"$tmp"
            continue
        fi

        prefix="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        tag="${BASH_REMATCH[3]}"
        asset="${BASH_REMATCH[4]}"
        trailing="${BASH_REMATCH[5]:-}"
        pinned=$((pinned + 1))

        latest="$(latest_release_tag "$repo" || true)"
        if [[ -z "$latest" ]]; then
            echo "  ${repo}: could not read the newest release; left at ${tag}" >&2
            failed=$((failed + 1))
            printf '%s\n' "$line" >>"$tmp"
            continue
        fi

        if [[ "$latest" == "$tag" ]]; then
            echo "  ${repo}: ${tag} is current"
            printf '%s\n' "$line" >>"$tmp"
            continue
        fi

        if ! asset_exists "${prefix}${latest}/${asset}"; then
            echo "  ${repo}: ${latest} publishes no ${asset}; left at ${tag}" >&2
            failed=$((failed + 1))
            printf '%s\n' "$line" >>"$tmp"
            continue
        fi

        echo "  ${repo}: ${tag} -> ${latest}  (${manifest})"
        bumped=$((bumped + 1))
        manifest_changed=true
        printf '%s\n' "${prefix}${latest}/${asset}${trailing}" >>"$tmp"
    done <"$manifest"

    if [[ "$manifest_changed" == true && "$dry_run" != true ]]; then
        cat "$tmp" >"$manifest"
    fi
    rm -f -- "$tmp"
    tmp=""
done

((pinned)) || echo "  no pinned release archives in the manifests"

if ((failed)); then
    echo "${failed} pinned archive(s) could not be checked; see the messages above." >&2
fi

if [[ "$dry_run" == true ]]; then
    echo
    echo "Dry run: no manifest was written and no image was rebuilt."
    exit 0
fi

cat <<EOF

${bumped} pinned archive(s) rewritten. Rebuilding, which also re-downloads every
line that tracks a branch rather than a fixed version. Review the manifest diff
before committing; a branch ref leaves no such record.
EOF

exec bash scripts/rebuild-code.sh --refresh "${rebuild_args[@]}"
