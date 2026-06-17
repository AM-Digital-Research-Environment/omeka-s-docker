#!/bin/bash
# Update the AMIRA MCP server to the latest upstream main.
# Usage: bash scripts/update-amira-mcp.sh
#
# The amira-mcp service builds from the upstream repo's main branch (see the
# build context in docker-compose.yml), so updating is just a fresh rebuild.
# --pull refreshes the node base image; --no-cache forces a new git clone and
# re-runs the build-time data snapshot fetch. The running site is untouched —
# only the amira-mcp container is recreated.

set -e
cd "$(dirname "$0")/.."

echo "==> Rebuilding amira-mcp from upstream main (fresh clone + data snapshot)..."
docker compose build --pull --no-cache amira-mcp

echo "==> Recreating the amira-mcp container..."
docker compose up -d amira-mcp

echo "==> Waiting for health..."
for i in $(seq 1 20); do
    status=$(docker inspect -f '{{.State.Health.Status}}' omeka-s-docker-amira-mcp-1 2>/dev/null || echo unknown)
    [ "$status" = "healthy" ] && break
    sleep 2
done
echo "    health: ${status:-unknown}"

echo "==> Version check:"
curl -s http://127.0.0.1:8080/mcp \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"update-script","version":"0"}}}' \
    | sed -n 's/.*"serverInfo":{\("name":"[^}]*"\)}.*/    \1/p'

echo "==> Done. Endpoint: https://data.africamultiple.uni-bayreuth.de/mcp"
