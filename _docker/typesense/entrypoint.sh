#!/bin/bash
# Entrypoint wrapper for the Typesense image (_docker/typesense/Dockerfile).
#
# Adds the conventional TYPESENSE_API_KEY_FILE (compose.secrets.yml mounts the
# key at /run/secrets/typesense_api_key) and otherwise starts the unchanged
# upstream server with the unchanged arguments. Without TYPESENSE_API_KEY_FILE
# it is a plain exec, so the default .env-based setup behaves exactly as
# before: an unset or empty key still makes Typesense exit with its own
# "API key is not specified" error.
set -euo pipefail

if [[ -n "${TYPESENSE_API_KEY_FILE:-}" ]]; then
    if [[ -n "${TYPESENSE_API_KEY:-}" ]]; then
        echo "ERROR: Both TYPESENSE_API_KEY and TYPESENSE_API_KEY_FILE are set; set only one of them." >&2
        exit 1
    fi
    if [[ ! -f "$TYPESENSE_API_KEY_FILE" || ! -r "$TYPESENSE_API_KEY_FILE" ]]; then
        echo "ERROR: TYPESENSE_API_KEY_FILE=$TYPESENSE_API_KEY_FILE is missing or not readable by uid $(id -u)." >&2
        echo "       Secret files must be world-readable (0644) inside a 0700 directory; see compose.secrets.yml." >&2
        exit 1
    fi
    # Typesense reads TYPESENSE_-prefixed variables as options, so the key
    # goes into the environment (not onto the command line, where every local
    # user could read it in the process list) ...
    TYPESENSE_API_KEY="$(< "$TYPESENSE_API_KEY_FILE")"
    export TYPESENSE_API_KEY
fi
# ... and the _FILE variable must not reach it as an unknown option.
unset TYPESENSE_API_KEY_FILE

exec /opt/typesense-server "$@"
