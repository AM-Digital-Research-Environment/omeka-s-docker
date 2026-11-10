#!/usr/bin/env bash
# Report version pins that Dependabot cannot see but that are behind their
# latest upstream release, as one tracking issue that is opened, refreshed and
# closed automatically. Run weekly by .github/workflows/untracked-pins.yml.
#
# Covered here (Dependabot owns image tags and action SHAs; amira-mcp has its
# own check in check-amira-mcp-release.sh):
#   - Omeka S core           Dockerfile ARG OMEKA_VERSION
#   - omeka-s-cli            Dockerfile toolfetcher ARG VERSION (+ its SHA)
#   - APCu                   Dockerfile install-php-extensions apcu-<version>
#   - GitHub release URLs    _docker/extra-*.txt and, when INCLUDE_AMIRA=true,
#                            deploy/amira/{modules,themes}.txt
#
# Unpinned entries (plain module names, gh: branch clones) resolve to the
# latest version at build time and are deliberately not reported.
#
# Environment:
#   GH_TOKEN, GH_REPO   used by gh
#   INCLUDE_AMIRA       "true" to check the AMIRA manifests
#   ISSUE_ASSIGNEE      optional GitHub login to assign (and so notify)
#   DRY_RUN             "true" to print the report without touching issues
#
# Exits 0 whether or not something is behind: being out of date is reported as
# an issue, not as a red scheduled workflow. Exits non-zero only when a pin can
# no longer be parsed, so a silent blind spot cannot creep in.

set -Eeuo pipefail

TITLE="Dependencies: versions Dependabot cannot track are behind upstream"
MARKER="<!-- untracked-pins-check -->"

rows=()
behind=0

# latest_tag <owner/repo> — the latest published (non-prerelease) release tag.
latest_tag() {
    gh api "repos/$1/releases/latest" -q .tag_name
}

# strip a leading "v" so 0.9.3 and v0.9.3 compare equal.
norm() { printf '%s' "${1#v}"; }

# check <component> <source file> <pinned> <owner/repo>
check() {
    local component="$1" file="$2" pinned="$3" repo="$4" latest status
    if [[ -z "$pinned" ]]; then
        echo "Could not read the ${component} pin from ${file}; has its line changed shape?" >&2
        exit 1
    fi
    latest="$(latest_tag "$repo")"
    if [[ -z "$latest" ]]; then
        echo "No published release found for ${repo}." >&2
        exit 1
    fi
    if [[ "$(norm "$pinned")" == "$(norm "$latest")" ]]; then
        status="current"
    else
        # Only report when upstream is actually newer, not when a pin runs ahead
        # of the "latest" release (e.g. a deliberately pinned prerelease).
        if [[ "$(printf '%s\n%s\n' "$(norm "$pinned")" "$(norm "$latest")" | sort -V | tail -n 1)" == "$(norm "$latest")" ]]; then
            status="behind"
            behind=$((behind + 1))
            rows+=("| ${component} | \`${file}\` | ${pinned} | [${latest}](https://github.com/${repo}/releases/tag/${latest}) |")
        else
            status="ahead"
        fi
    fi
    printf '%-28s pinned=%-10s latest=%-10s %s\n' "$component" "$pinned" "$latest" "$status"
}

# --- Dockerfile -------------------------------------------------------------

omeka="$(sed -nE 's/^ARG OMEKA_VERSION=([0-9][^[:space:]]*)$/\1/p' Dockerfile | head -n 1)"
check "Omeka S core" Dockerfile "$omeka" omeka/omeka-s

# The toolfetcher stage's ARG VERSION is the first ARG VERSION in the file.
cli="$(sed -nE 's/^ARG VERSION=([0-9][^[:space:]]*)$/\1/p' Dockerfile | head -n 1)"
check "omeka-s-cli" Dockerfile "$cli" GhentCDH/Omeka-S-Cli

apcu="$(sed -nE 's/^[[:space:]]+apcu-([0-9][0-9.]*)[[:space:]\\]*$/\1/p' Dockerfile | head -n 1)"
check "APCu" Dockerfile "$apcu" krakjoe/apcu

# --- Release-archive URLs in module/theme manifests -------------------------

manifests=(_docker/extra-modules.txt _docker/extra-themes.txt)
if [[ "${INCLUDE_AMIRA:-false}" == "true" ]]; then
    manifests+=(deploy/amira/modules.txt deploy/amira/themes.txt)
fi

for file in "${manifests[@]}"; do
    [[ -f "$file" ]] || continue
    while read -r owner repo tag; do
        check "$repo" "$file" "$tag" "${owner}/${repo}"
    done < <(grep -v '^[[:space:]]*#' "$file" \
        | sed -nE 's#.*https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/.*#\1 \2 \3#p')
done

echo "behind=${behind}"

# --- Issue ------------------------------------------------------------------

if [[ "${DRY_RUN:-false}" == "true" ]]; then
    exit 0
fi

existing="$(gh issue list --state open --limit 100 --json number,body \
    -q "[.[] | select(.body | contains(\"${MARKER}\"))] | .[0].number // empty")"

if (( behind == 0 )); then
    if [[ -n "$existing" ]]; then
        gh issue close "$existing" --comment "Everything this check tracks is on its latest upstream release."
        echo "Closed issue #${existing}."
    fi
    exit 0
fi

table="$(printf '%s\n' "${rows[@]}")"
body="$(cat <<EOF
${MARKER}
These pins live where no Dependabot ecosystem can parse them, so this weekly
check stands in for it. Each one is behind its latest upstream release:

| Component | Pinned in | Pinned | Latest |
|---|---|---|---|
${table}

How to move them:

- **Omeka S core**: bump \`ARG OMEKA_VERSION\` in the Dockerfile, then follow
  \`scripts/update-omeka.sh\`.
- **omeka-s-cli**: bump \`ARG VERSION\` *and* \`ARG SHA\` in the toolfetcher
  stage (\`sha256sum\` of the release's \`omeka-s-cli.phar\`).
- **APCu**: bump \`apcu-<version>\` in the \`install-php-extensions\` list.
- **Modules and themes**: \`scripts/update-extensions.sh\` updates the running
  deployment; edit the release URL in the manifest to move the default.

This issue updates itself as pins change and closes once all are current.
EOF
)"

assignee_args=()
if [[ -n "${ISSUE_ASSIGNEE:-}" ]]; then
    assignee_args=(--add-assignee "$ISSUE_ASSIGNEE")
fi

if [[ -z "$existing" ]]; then
    create_args=()
    [[ -n "${ISSUE_ASSIGNEE:-}" ]] && create_args=(--assignee "$ISSUE_ASSIGNEE")
    gh issue create --title "$TITLE" --body "$body" "${create_args[@]}"
    echo "Opened a tracking issue."
    exit 0
fi

current_body="$(gh issue view "$existing" --json body -q .body)"
if [[ "$current_body" == "$body" ]]; then
    echo "Issue #${existing} is already up to date."
    exit 0
fi

gh issue edit "$existing" --title "$TITLE" --body "$body" "${assignee_args[@]}"
# An edit does not notify anyone; a comment does.
gh issue comment "$existing" --body "The list of outdated pins changed; see the updated description."
echo "Updated issue #${existing}."
