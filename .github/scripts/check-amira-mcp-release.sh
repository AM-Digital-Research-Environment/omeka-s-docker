#!/usr/bin/env bash
# Compare the amira-mcp release pinned in compose.amira.yml against the latest
# published upstream release, and open (or refresh) a single tracking issue
# whenever the pin is behind.
#
# Dependabot cannot watch this pin: it lives inside a build-context git URL
# rather than an `image:` tag, and no Dependabot ecosystem parses that. This
# check stands in for it. Run weekly by .github/workflows/amira-mcp-release.yml.
#
# Exits 0 whether or not the pin is behind — being out of date is reported as
# an issue, not as a red scheduled workflow.

set -Eeuo pipefail

UPSTREAM="${UPSTREAM:-AM-Digital-Research-Environment/amira-mcp-server}"
TITLE_PREFIX="AMIRA MCP: "

pinned="$(sed -nE 's/.*amira-mcp-server\.git#\$\{AMIRA_MCP_VERSION:-([^}]+)\}.*/\1/p' \
    compose.amira.yml | head -n 1)"
if [[ -z "$pinned" ]]; then
    echo "Could not read the amira-mcp pin from compose.amira.yml." >&2
    echo "Has the build context line changed shape?" >&2
    exit 1
fi

latest="$(gh api "repos/${UPSTREAM}/releases/latest" -q .tag_name)"
if [[ ! "$latest" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unexpected upstream release tag: ${latest}" >&2
    exit 1
fi

echo "pinned=${pinned} latest=${latest}"
if [[ "$pinned" == "$latest" ]]; then
    echo "amira-mcp is on the latest release."
    exit 0
fi

title="${TITLE_PREFIX}${latest} available (pinned ${pinned})"
body="$(cat <<EOF
\`compose.amira.yml\` pins amira-mcp at **${pinned}**; the latest published
upstream release is **${latest}**.

Dependabot cannot see this pin — it lives in a build-context git URL rather
than an image tag — so this weekly check stands in for it.

To move the deployment, on the server:

\`\`\`bash
bash deploy/amira/update-amira-mcp.sh latest
\`\`\`

That rewrites \`AMIRA_MCP_VERSION\` in \`.env\`, rebuilds only the amira-mcp
service, and restores the previous \`.env\` if the build fails. To move the
repository default as well, update the pin in \`compose.amira.yml\` — it is the
single source of truth that this check reads.

Upstream release: https://github.com/${UPSTREAM}/releases/tag/${latest}
EOF
)"

# List and filter rather than using `gh issue list --search`: the search index
# lags behind issue creation, which would let duplicates through.
existing="$(gh issue list --state open --limit 100 --json number,title \
    -q "[.[] | select(.title | startswith(\"${TITLE_PREFIX}\"))] | .[0].number // empty")"

if [[ -z "$existing" ]]; then
    gh issue create --title "$title" --body "$body"
    echo "Opened a tracking issue."
    exit 0
fi

current_title="$(gh issue view "$existing" --json title -q .title)"
if [[ "$current_title" == "$title" ]]; then
    echo "Issue #${existing} already tracks ${latest}."
    exit 0
fi

gh issue edit "$existing" --title "$title" --body "$body"
echo "Updated issue #${existing} to track ${latest}."
