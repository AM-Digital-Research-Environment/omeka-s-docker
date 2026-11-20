#!/usr/bin/env bash
# Guard against committing the AMIRA curator MCP secrets: the Omeka service
# key and the personal-token file (deploy/amira/README.md#curator-mcp-endpoint),
# and the file-based secrets of compose.secrets.yml (secrets/).
# Trivy's secret scan (security.yml) knows generic credential formats; this
# knows ours. It fails when:
#
#   - secrets/ (compose.secrets.yml's default SECRETS_DIR) is not ignored by
#     git and the Docker build context, or anything is tracked under it;
#   - the real curator secret paths are not ignored by git;
#   - anything is tracked under deploy/amira/curator-secrets/;
#   - a template (deploy/amira/curator-*.example) holds a line that is not a
#     comment, i.e. a value someone filled in;
#   - any tracked file holds a personal token (amira_cur_…), a tokens-file
#     line (name and 64 hex characters) or a filled-in key_identity /
#     key_credential.
#
# Runs on the checkout only; no containers.

set -Eeuo pipefail

cd "$(dirname "$0")/../.."

failures=0
fail() {
    echo "ERROR: $*" >&2
    failures=$((failures + 1))
}

# compose.secrets.yml: one file per secret in SECRETS_DIR (default ./secrets).
for name in mysql_password omeka_secret_key typesense_api_key omeka_admin_password; do
    git check-ignore -q --no-index "secrets/$name" || fail "secrets/$name is not ignored by git (.gitignore)"
done
tracked="$(git ls-files -- secrets)"
[[ -z "$tracked" ]] || fail "files are committed under secrets/:"$'\n'"$tracked"
grep -qxE '/?secrets/?' .dockerignore || fail "secrets/ is not excluded from the build context (.dockerignore)"

secrets_dir=deploy/amira/curator-secrets

for path in "$secrets_dir/omeka-key" "$secrets_dir/tokens"; do
    git check-ignore -q --no-index "$path" || fail "$path is not ignored by git (.gitignore)"
done

tracked="$(git ls-files -- "$secrets_dir")"
[[ -z "$tracked" ]] || fail "files are committed under $secrets_dir/:"$'\n'"$tracked"

for template in deploy/amira/curator-omeka-key.example deploy/amira/curator-tokens.example; do
    if [[ ! -f "$template" ]]; then
        fail "$template is missing"
    elif grep -nvE '^[[:space:]]*(#|$)' "$template" >&2; then
        fail "$template must hold comments only (the lines above are not)"
    fi
done

# A personal token as tokenCli prints it (amira_cur_ + 43 base64url
# characters); a tokens-file line (a name, then exactly 64 hex characters);
# a key line with a real-looking value (Omeka generates 32 alphanumerics).
if git grep -nIE \
    -e 'amira_cur_[A-Za-z0-9_-]{20,}' \
    -e '^[[:space:]]*[A-Za-z0-9][A-Za-z0-9._@-]{0,63}[[:space:]]+[0-9a-fA-F]{64}[[:space:]]*$' \
    -e 'key_(identity|credential)[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9]{20,}' \
    >&2; then
    fail "tracked files above hold what looks like a curator token, token hash or Omeka key"
fi

if (( failures > 0 )); then
    exit 1
fi
echo "No curator MCP or compose.secrets.yml secrets are committed."
