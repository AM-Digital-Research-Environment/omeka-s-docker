#!/usr/bin/env bash
# Turn the per-image Trivy summaries written by .github/workflows/security.yml
# into a single tracking issue: opened when any image has fixable HIGH or
# CRITICAL vulnerabilities, refreshed (with a notifying comment) when the
# numbers change, and closed when every image is clean.
#
# Usage: report-image-scan.sh <directory of <image>.json summaries>
#
# Environment:
#   GH_TOKEN, GH_REPO   used by gh
#   RUN_URL             link to the workflow run, for the job summaries
#   EXPECTED_IMAGES     how many summaries a complete run produces
#   ISSUE_ASSIGNEE      optional GitHub login to assign (and so notify)

set -Eeuo pipefail

dir="${1:?usage: report-image-scan.sh <summary dir>}"
TITLE="Security: fixable HIGH/CRITICAL vulnerabilities in container images"
MARKER="<!-- image-scan-report -->"

shopt -s nullglob
files=("$dir"/*.json)
found="${#files[@]}"
expected="${EXPECTED_IMAGES:-$found}"

if (( found == 0 )); then
    echo "No scan summaries found; every image job failed before scanning." >&2
    exit 1
fi

rows="$(jq -rs 'sort_by(.name)[] | select(.critical + .high > 0)
    | "| \(.name) | `\(.ref | split("@")[0])` | \(.critical) | \(.high) | \(.medium) |"' "${files[@]}")"
blocking="$(jq -s 'map(.critical + .high) | add' "${files[@]}")"
scanned="$(jq -rs 'map(.name) | sort | join(", ")' "${files[@]}")"
echo "scanned=${scanned} blocking=${blocking} (${found}/${expected} images)"

incomplete=""
if (( found < expected )); then
    incomplete="
> **Incomplete run:** only ${found} of ${expected} images were scanned
> (${scanned}). A build or pull failed; check the run before trusting the
> list below."
fi

existing="$(gh issue list --state open --limit 100 --json number,body \
    -q "[.[] | select(.body | contains(\"${MARKER}\"))] | .[0].number // empty")"

if (( blocking == 0 )) && (( found == expected )); then
    if [[ -n "$existing" ]]; then
        gh issue close "$existing" --comment "The latest scheduled scan found no fixable HIGH/CRITICAL vulnerabilities: ${RUN_URL:-}"
        echo "Closed issue #${existing}."
    fi
    exit 0
fi
if (( blocking == 0 )); then
    echo "No findings, but the run was incomplete; leaving any open issue as is."
    exit 0
fi

body="$(cat <<EOF
${MARKER}
The weekly image scan found vulnerabilities that **already have a fix
available** in images this repository builds or runs.
${incomplete}

| Image | Reference | Critical | High | Medium |
|---|---|---|---|---|
${rows}

Details, per finding: **Security → Code scanning** (filter by tool *Trivy*),
or the job summaries of the run: ${RUN_URL:-}

Typical fixes:

- **OS packages** (debian/alpine): a rebuild picks up patched packages once
  the base image is refreshed. Merge pending Dependabot docker PRs, then
  rebuild (\`scripts/rebuild-code.sh\`, or \`docker compose build --pull\`).
- **PHP packages** under \`modules/*/vendor\` or \`vendor\`: they ship inside
  the module or Omeka release; update the module
  (\`scripts/update-extensions.sh\`) or report it upstream.
- **mysql / typesense / oxigraph / amira-mcp**: wait for, or bump to, an
  upstream image or release that includes the fix.

This issue updates itself on each scheduled scan and closes when every image
is clean.
EOF
)"

if [[ -z "$existing" ]]; then
    create_args=()
    [[ -n "${ISSUE_ASSIGNEE:-}" ]] && create_args=(--assignee "$ISSUE_ASSIGNEE")
    gh issue create --title "$TITLE" --body "$body" --label security "${create_args[@]}" \
        || gh issue create --title "$TITLE" --body "$body" "${create_args[@]}"
    echo "Opened a tracking issue."
    exit 0
fi

# Compare only the table so a new run URL alone does not re-notify.
old_table="$(gh issue view "$existing" --json body -q .body | grep '^| ' || true)"
new_table="$(printf '%s\n' "$body" | grep '^| ' || true)"
if [[ "$old_table" == "$new_table" ]]; then
    gh issue edit "$existing" --body "$body"
    echo "Issue #${existing}: findings unchanged; refreshed the run link."
    exit 0
fi

edit_args=()
[[ -n "${ISSUE_ASSIGNEE:-}" ]] && edit_args=(--add-assignee "$ISSUE_ASSIGNEE")
gh issue edit "$existing" --title "$TITLE" --body "$body" "${edit_args[@]}"
# An edit does not notify anyone; a comment does.
gh issue comment "$existing" --body "The findings changed (now ${blocking} fixable HIGH/CRITICAL in total); see the updated description."
echo "Updated issue #${existing}."
