#!/usr/bin/env bash
# Read-only operational summary. Does not print environments, credentials or logs.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

docker info --format 'Docker {{.ServerVersion}}; host memory {{.MemTotal}} bytes'
ids="$(docker compose ps --all -q)"
[[ -n "$ids" ]] || { echo "No containers found for the active Compose project." >&2; exit 1; }
mapfile -t containers <<< "$ids"
status=0
for container in "${containers[@]}"; do
    docker inspect --format '{{.Name}}: state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} oom_killed={{.State.OOMKilled}} image={{.Image}}' "$container"
    state="$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container")"
    [[ "$state" == 'running healthy' ]] || status=1
done
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}' "${containers[@]}"
echo "Container health does not prove backups, TLS or application workflows work."
echo "Inspect peak memory during imports; Docker does not restart a container solely because it is unhealthy."
exit "$status"
