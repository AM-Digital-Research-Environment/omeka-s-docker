#!/usr/bin/env bash
# Serve the DRE-LinkedData dump as a read-only SPARQL endpoint, and reload it
# whenever the module publishes a new one.
#
# The module writes files/dre-linked-data/dump.nt.gz, then state.json, each by
# rename (DRELinkedData\Dump\DumpStore::publish). This polls state.json; when
# its sha256 changes, the dump is copied, checked against that checksum, and
# bulk-loaded into a fresh store directory named after it, while the current
# store keeps answering. Only a complete load replaces the running server, so
# a query never sees a partial graph; a failed or mismatched load leaves the
# old store in place and is retried on the next poll. A store whose load
# completed is reused on restart instead of being loaded again.
#
# Oxigraph listens on loopback only; socat relays a Unix socket on the shared
# sparql_socket volume to it. The container has no network (network_mode:
# none), so SPARQL SERVICE clauses, which Oxigraph would otherwise execute
# over HTTP, cannot reach Omeka, the host, or the internet.
#
# Oxigraph's --timeout-s only cancels a query while it reads from the store;
# a join over results already in memory (a cross product, say) never checks
# and runs on. So a watchdog also samples the server's CPU time: saturated for
# twice the query timeout means a query has escaped it, and the server is
# restarted on the same store, which takes well under a second.
#
# Neither bounds a response that keeps streaming: the timeouts apply to each
# read and write, not to the request. So each connection on the socket is
# relayed by its own socat under `timeout`, and closed after
# SPARQL_REQUEST_LIMIT seconds whatever it is doing. A slow or huge download
# cannot hold one of the endpoint's few concurrent slots for long.

set -Eeuo pipefail

port=7878

# One relayed connection (socat runs `sparql-entrypoint relay` per client).
if [[ "${1:-}" == relay ]]; then
    exec timeout --kill-after=2 "${SPARQL_REQUEST_LIMIT:-60}" socat STDIO "TCP:127.0.0.1:$port"
fi

dump_dir=${SPARQL_DUMP_DIR:-/media/dre-linked-data}
data_dir=/data
socket=/run/sparql/sparql.sock
query_timeout=${SPARQL_QUERY_TIMEOUT:-30}
poll_interval=${SPARQL_POLL_INTERVAL:-60}
watchdog_limit=$((query_timeout * 2))
tick=5

server_pid=
relay_pid=
current=

log() {
    printf '%s sparql: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

shutdown() {
    log "stopping"
    kill $relay_pid $server_pid 2>/dev/null || true
    wait
    exit 0
}
trap shutdown TERM INT

# The sha256 of the published dump, or nothing before the first one.
published_sha() {
    sed -n 's/^[[:space:]]*"sha256":[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' \
        "$dump_dir/state.json" 2>/dev/null | head -n 1 || true
}

# Build the store for dump $1 unless a completed one is already there.
load() {
    local sha=$1 store="$data_dir/$1" incoming="$data_dir/incoming.nt.gz" actual
    [[ -f "$store.complete" ]] && return 0

    rm -rf "$store" "$incoming"
    cp "$dump_dir/dump.nt.gz" "$incoming"
    actual=$(sha256sum "$incoming" | cut -d ' ' -f 1)
    if [[ "$actual" != "$sha" ]]; then
        # state.json and the dump are renamed one after the other; this is
        # the instant between the two. The next poll sees the matching pair.
        log "dump does not match state.json yet; retrying on the next poll"
        rm -f "$incoming"
        return 1
    fi

    log "loading dump $sha"
    # Lower priority than the serving process, so queries keep their share of
    # the container's CPU while a reload runs.
    if ! nice -n 10 oxigraph load --location "$store" --file "$incoming"; then
        log "load failed; keeping the current store"
        rm -rf "$store" "$incoming"
        return 1
    fi
    rm -f "$incoming"
    # Compacts the freshly loaded store, as Oxigraph recommends for a
    # read-only workload. Not essential: a store it fails on still serves.
    nice -n 10 oxigraph optimize --location "$store" || log "optimize failed; serving the store as loaded"
    touch "$store.complete"
}

start_server() {
    local store="$data_dir/$1"
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    oxigraph serve-read-only --location "$store" --bind "127.0.0.1:$port" \
        --timeout-s "$query_timeout" &
    server_pid=$!
    for _ in $(seq 1 50); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            return 0
        fi
        kill -0 "$server_pid" 2>/dev/null || break
        sleep 0.2
    done
    log "server did not start"
    exit 1
}

# Remove every store except the one being served.
prune() {
    local keep=$1 entry
    for entry in "$data_dir"/* "$data_dir"/.[!.]*; do
        [[ -e "$entry" ]] || continue
        case "${entry##*/}" in
            "$keep" | "$keep.complete") ;;
            *) rm -rf "$entry" ;;
        esac
    done
}

# CPU ticks the server may use in one tick before it counts as saturated: 80%
# of the container's CPU limit (cgroup v2 cpu.max), or of one CPU without one.
saturation_ticks() {
    local quota period clk
    read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null || quota=max
    clk=$(getconf CLK_TCK)
    if [[ "$quota" == max ]]; then
        quota=1 period=1
    fi
    echo $((tick * clk * quota * 8 / (period * 10)))
}

server_ticks() {
    local stat fields
    read -r stat < "/proc/$server_pid/stat" 2>/dev/null || { echo 0; return; }
    # Fields 14 and 15 (utime, stime), counted after the ")" ending the name.
    stat=${stat##*) }
    read -r -a fields <<< "$stat"
    echo $((fields[11] + fields[12]))
}

socat "UNIX-LISTEN:$socket,fork,unlink-early,mode=0666" "EXEC:$0 relay" &
relay_pid=$!

saturated=$(saturation_ticks)
waiting_logged=false
next_poll=0
busy=0
last_ticks=0
while true; do
    if ((SECONDS >= next_poll)); then
        sha=$(published_sha)
        if [[ -z "$sha" ]]; then
            if [[ -z "$current" && "$waiting_logged" == false ]]; then
                log "no dump at $dump_dir yet; generate one in DRE Linked Data's configuration"
                waiting_logged=true
            fi
        elif [[ "$sha" != "$current" ]] && load "$sha"; then
            start_server "$sha"
            current=$sha
            prune "$current"
            log "serving dump $current"
            busy=0
            last_ticks=0
        fi
        next_poll=$((SECONDS + poll_interval))
    fi

    if [[ -n "$server_pid" ]]; then
        ticks=$(server_ticks)
        if ((ticks - last_ticks >= saturated)); then
            busy=$((busy + tick))
        else
            busy=0
        fi
        last_ticks=$ticks
        if ((busy >= watchdog_limit)); then
            log "server saturated for ${busy}s, past the ${query_timeout}s query timeout; restarting it"
            start_server "$current"
            busy=0
            last_ticks=0
        fi
    fi

    if ! kill -0 "$relay_pid" 2>/dev/null; then
        log "socket relay exited"
        exit 1
    fi
    if [[ -n "$server_pid" ]] && ! kill -0 "$server_pid" 2>/dev/null; then
        log "server exited"
        exit 1
    fi

    sleep "$tick" &
    wait $! || true
done
