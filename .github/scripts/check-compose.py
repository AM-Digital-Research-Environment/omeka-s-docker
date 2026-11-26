#!/usr/bin/env python3
"""Assert security and wiring invariants on `docker compose config --format json`."""

from __future__ import annotations

import json
from pathlib import Path
import os
import re
import sys
from typing import Any
from urllib.parse import urlsplit


def fail(message: str) -> None:
    errors.append(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def environment(service: dict[str, Any]) -> dict[str, str]:
    value = service.get("environment", {})
    if isinstance(value, dict):
        return {str(key): str(item) for key, item in value.items()}
    result: dict[str, str] = {}
    for entry in value:
        key, _, item = str(entry).partition("=")
        result[key] = item
    return result


def mounts_at(service: dict[str, Any], target: str) -> list[dict[str, Any]]:
    return [
        mount
        for mount in service.get("volumes", [])
        if isinstance(mount, dict) and mount.get("target") == target
    ]


def tmpfs_targets(service: dict[str, Any]) -> set[str]:
    return {str(entry).split(":", 1)[0] for entry in service.get("tmpfs", [])}


def tmpfs_options(service: dict[str, Any], target: str) -> dict[str, str] | None:
    for entry in service.get("tmpfs", []):
        path, _, options = str(entry).partition(":")
        if path == target:
            return dict(
                (option.partition("=")[0], option.partition("=")[2])
                for option in options.split(",")
                if option
            )
    return None


def size_bytes(value: str) -> int:
    """Parse a Compose/tmpfs size such as 536870912, 128M or 1g."""
    match = re.fullmatch(r"(\d+)\s*([kmg]?)b?", str(value).strip().lower())
    if not match:
        return 0
    return int(match.group(1)) * {"": 1, "k": 1024, "m": 1024**2, "g": 1024**3}[match.group(2)]


def limits(service: dict[str, Any]) -> dict[str, Any]:
    return ((service.get("deploy") or {}).get("resources") or {}).get("limits") or {}


def check_node_heap(service_name: str) -> None:
    """A Node MCP server must cap its V8 heap below its cgroup limit, with room
    left for its tmpfs mounts (charged to the same limit) and V8's non-heap
    memory; otherwise it dies with a heap OOM or is OOM-killed."""
    service = services[service_name]
    node_options = environment(service).get("NODE_OPTIONS", "")
    heap = re.search(r"--max-old-space-size=(\d+)\b", node_options)
    require(heap is not None, f"{service_name} must cap its V8 heap with NODE_OPTIONS=--max-old-space-size")
    memory = size_bytes(str(limits(service).get("memory", "")))
    require(memory > 0, f"{service_name} must have a memory limit")
    if heap is None or memory <= 0:
        return
    tmpfs_total = sum(
        size_bytes((tmpfs_options(service, target) or {}).get("size", "0"))
        for target in tmpfs_targets(service)
    )
    # V8 keeps code, the young generation and buffers outside the old-space
    # heap; 32M is a floor, not a recommendation.
    require(
        int(heap.group(1)) * 1024**2 + 32 * 1024**2 <= memory,
        f"{service_name} V8 heap must stay at least 32M below its memory limit",
    )
    if service_name == "amira-mcp-curator":
        # Its cache tmpfs holds data on every run, so heap + tmpfs must fit.
        require(
            int(heap.group(1)) * 1024**2 + tmpfs_total < memory,
            f"{service_name} V8 heap plus its tmpfs mounts must stay under its memory limit",
        )


def check_forwarded_for(service_name: str, template: str, path: str) -> None:
    """AMIRA_TRUST_PROXY on an MCP service and X-Forwarded-For in the nginx
    location in front of it are one decision; see where this is called."""
    service_env = environment(services[service_name])
    # Mirrors the upstream parseBool (src/config.ts): anything else is false.
    trusts_proxy = service_env.get("AMIRA_TRUST_PROXY", "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    templates = mounts_at(services["web"], f"/etc/nginx/templates/extra-locations/{template}")
    location_conf: str | None = None
    if templates:
        try:
            with open(str(templates[0].get("source", "")), encoding="utf-8") as handle:
                location_conf = handle.read()
        except OSError as error:
            fail(f"cannot read the {path} location template: {error}")
    if location_conf is None:
        return
    forwarded_for = [
        line.strip()
        for line in location_conf.splitlines()
        if re.match(r"\s*proxy_set_header\s+X-Forwarded-For\b", line, re.IGNORECASE)
    ]
    require(
        len(forwarded_for) == 1,
        f"the {path} location must set X-Forwarded-For exactly once",
    )
    overwrites = bool(forwarded_for) and "$proxy_add_x_forwarded_for" not in forwarded_for[0]
    require(
        trusts_proxy,
        f"{service_name} must set AMIRA_TRUST_PROXY so its rate limit is per visitor"
        " rather than one bucket shared by everyone behind the proxy",
    )
    require(
        not (trusts_proxy and not overwrites),
        f"the {path} location appends to X-Forwarded-For while {service_name} trusts"
        " it; the header is the rate-limit key, so a caller-supplied entry"
        " would make the limit forgeable. Use `proxy_set_header"
        " X-Forwarded-For $remote_addr`",
    )


variant = sys.argv[1] if len(sys.argv) > 1 else "base"
# "<variant>-tls" (and plain "tls" for the base stack) is the same stack with
# compose.tls.yml layered on last; see check_tls() below.
is_tls = variant == "tls" or variant.endswith("-tls")
variant = "base" if variant == "tls" else variant.removesuffix("-tls")
# "<variant>-secrets" (and plain "secrets" for the base stack) is the same
# stack with compose.secrets.yml layered on; see check_secrets() below.
is_secrets = variant == "secrets" or variant.endswith("-secrets")
variant = "base" if variant == "secrets" else variant.removesuffix("-secrets")
usage = (
    "usage: check-compose.py base|amira|amira-curator|immutable|amira-immutable,"
    " optionally with -secrets appended (or just: secrets), then optionally -tls"
    " for a non-AMIRA variant (or just: tls, secrets-tls, immutable-tls, ...)"
)
if variant not in {"base", "amira", "amira-curator", "immutable", "amira-immutable"}:
    raise SystemExit(usage)
# compose.tls.yml takes the host's ports 80/443 and stops publishing nginx on
# the loopback, which is where the AMIRA host proxy expects it; the two are
# alternatives, so there is no contract for the combination.
if is_tls and variant.startswith("amira"):
    raise SystemExit(usage)

# Modules/themes are admin-managed volumes by default; compose.immutable.yml
# drops them back into the image layer.
is_amira = variant in {"amira", "amira-curator", "amira-immutable"}
is_immutable = variant in {"immutable", "amira-immutable"}
# amira-curator is the AMIRA overlay rendered with --profile curator too; every
# other variant must leave the curator service out.
is_curator = variant == "amira-curator"

config = json.load(sys.stdin)
services: dict[str, dict[str, Any]] = config.get("services", {})
errors: list[str] = []

expected_services = {"web", "php", "db", "typesense"}
if is_amira:
    # CI renders the AMIRA variants with --profile sparql so the opt-in
    # service is checked too.
    expected_services.update({"amira-mcp", "sparql"})
if is_curator:
    expected_services.add("amira-mcp-curator")
if is_tls:
    expected_services.add("caddy")
missing_services = expected_services - services.keys()
require(not missing_services, f"required services are missing: {', '.join(sorted(missing_services))}")
require(("amira-mcp" in services) == is_amira, "AMIRA overlay service mismatch")
# The curator service serves private data, so it stays behind its profile:
# present when the profile is asked for, never by default.
require(
    ("amira-mcp-curator" in services) == is_curator,
    "amira-mcp-curator must start only with the curator profile",
)
require(("caddy" in services) == is_tls, "caddy must come from compose.tls.yml only")

if missing_services:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

if not errors:
    php_env = environment(services["php"])
    db_env = environment(services["db"])
    for name in ("MYSQL_DATABASE", "MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_PASSWORD_FILE"):
        require(php_env.get(name) == db_env.get(name), f"php/db {name} values differ")
    require(
        php_env.get("MYSQL_DATABASE") == os.environ["MYSQL_DATABASE"],
        "custom MYSQL_DATABASE did not reach php",
    )
    require(
        php_env.get("MYSQL_USER") == os.environ["MYSQL_USER"],
        "custom MYSQL_USER did not reach php",
    )

for name, service in services.items():
    require(not service.get("privileged", False), f"{name} must not be privileged")
    require(service.get("network_mode") != "host", f"{name} must not use the host network")
    require(service.get("pid") != "host", f"{name} must not use the host PID namespace")
    require(service.get("ipc") != "host", f"{name} must not use the host IPC namespace")
    security_opt = service.get("security_opt", [])
    require(
        "no-new-privileges:true" in security_opt,
        f"{name} must set no-new-privileges",
    )
    require("ALL" in service.get("cap_drop", []), f"{name} must drop all capabilities")
    require(service.get("restart") == "unless-stopped", f"{name} restart policy changed")
    # A process/thread cap per service, so a runaway or exploited process
    # cannot fork-bomb the host. It lives in deploy.resources.limits.pids:
    # Compose rejects a service-level pids_limit next to other deploy limits.
    pids = limits(service).get("pids")
    require(
        isinstance(pids, int) and 0 < pids <= 1024,
        f"{name} must set deploy.resources.limits.pids (1-1024)",
    )
    require(not service.get("pids_limit"), f"{name} must set its pids limit in one place only")
    # One service faces the host: nginx, or Caddy in front of it with
    # compose.tls.yml (check_tls asserts that web then publishes nothing).
    if name != ("caddy" if is_tls else "web"):
        require(not service.get("ports"), f"{name} must not publish host ports")
    for mount in service.get("volumes", []):
        if not isinstance(mount, dict):
            continue
        source = str(mount.get("source", ""))
        target = str(mount.get("target", ""))
        require(
            source != "/var/run/docker.sock" and target != "/var/run/docker.sock",
            f"{name} must not mount the Docker socket",
        )

for name in ("web", "php", "db", "typesense", *(("caddy",) if is_tls else ())):
    require(services[name].get("read_only") is True, f"{name} root filesystem must be read-only")
# Only nginx needs capabilities (binding port 80, dropping to its worker user).
# Caddy binds 80/443 through the namespaced unprivileged-port sysctl instead.
for name, service in services.items():
    if name != "web":
        require(not service.get("cap_add"), f"{name} must not add capabilities")

# MySQL runs as the image's mysql user (uid 999 in the pinned image) from the
# start, so its entrypoint never needs root or the chown capabilities. Its
# writable paths outside the data volume are tmpfs owned by that user.
db = services["db"]
require(db.get("user") == "999:999", "db must run as the image's mysql user (999:999)")
for target in ("/tmp", "/var/run/mysqld"):
    options = tmpfs_options(db, target)
    require(
        options is not None and options.get("uid") == "999" and options.get("gid") == "999",
        f"db needs a tmpfs at {target} owned by 999:999",
    )

# Typesense reads TYPESENSE_API_KEY from its environment. On the command line
# the key would be readable by every local user in the host's process list.
typesense = services["typesense"]
require(
    not any("api-key" in str(argument) for argument in typesense.get("command") or []),
    "typesense must not receive its API key on the command line",
)
for name in ("TYPESENSE_API_KEY", "TYPESENSE_API_KEY_FILE"):
    require(
        environment(typesense).get(name) == environment(services["php"]).get(name),
        f"typesense and php must share {name}",
    )

# db and typesense have no business reaching the internet or the host's other
# networks; php keeps frontend for its own outbound traffic.
require(
    (config.get("networks", {}).get("backend") or {}).get("internal") is True,
    "the backend network must be internal",
)

# Settings the entrypoint and nginx templates read; a missing pass-through
# would silently fall back to the template defaults.
php_env_all = environment(services["php"])
for name in ("OMEKA_SESSION_COOKIE_SECURE", "OMEKA_SESSION_COOKIE_SAMESITE", "OMEKA_AUTO_INSTALL_MODULES"):
    require(name in php_env_all, f"php must pass {name} through")
require(
    php_env_all.get("OMEKA_SESSION_COOKIE_SECURE") in {"true", "false"},
    "OMEKA_SESSION_COOKIE_SECURE must default to true or false",
)
if not is_tls:
    # The base stack speaks plain HTTP, where browsers drop a Secure cookie
    # and nobody could log in. compose.tls.yml flips it (check_tls).
    require(
        php_env_all.get("OMEKA_SESSION_COOKIE_SECURE") == "false",
        "OMEKA_SESSION_COOKIE_SECURE must default to false on the plain-HTTP stack",
    )
web_env = environment(services["web"])
envsubst_filter = web_env.get("NGINX_ENVSUBST_FILTER", "").replace("$$", "$")
for name in (
    "SERVER_NAME",
    "FRAME_ANCESTORS",
    "NGINX_TRUSTED_PROXY_CIDR",
    "NGINX_HSTS_MAX_AGE",
    "NGINX_API_RATE_LIMIT",
    "NGINX_API_RATE",
):
    require(name in web_env, f"web must pass {name} through")
    require(
        re.search(envsubst_filter, name) is not None if envsubst_filter else False,
        f"NGINX_ENVSUBST_FILTER must include {name}, or the template keeps it unsubstituted",
    )
require(
    re.fullmatch(r"\d+", web_env.get("NGINX_HSTS_MAX_AGE", "")) is not None,
    "NGINX_HSTS_MAX_AGE must be a whole number of seconds",
)
if is_amira:
    for name in ("amira-mcp", "sparql", *(("amira-mcp-curator",) if is_curator else ())):
        require(
            services[name].get("read_only") is True,
            f"{name} root filesystem must be read-only",
        )

web_ports = services["web"].get("ports", [])
if is_tls:
    # Caddy owns 80/443 and reaches nginx over the frontend network; a
    # published nginx port would collide with Caddy's or bypass HTTPS.
    require(not web_ports, "web must not publish a port with compose.tls.yml")
else:
    require(len(web_ports) == 1, "web must publish exactly one port")
    if web_ports and isinstance(web_ports[0], dict):
        require(web_ports[0].get("host_ip") == "127.0.0.1", "web must bind to loopback by default")

for name in ("web", "php", "db", "typesense", *(("caddy",) if is_tls else ())):
    require("healthcheck" in services[name], f"{name} healthcheck is missing")

# db and typesense are thin local builds over an upstream release (db drops
# gosu and MySQL Shell; typesense adds OS updates). Each base image must stay
# digest-pinned in its own Dockerfile.
for name, directory, repository in (
    ("db", "_docker/mysql", "mysql"),
    ("typesense", "_docker/typesense", "typesense/typesense"),
):
    context = str(services[name].get("build", {}).get("context", ""))
    require(context.rstrip("/").endswith(directory), f"{name} must build from {directory}")
    require("image" not in services[name], f"{name} must be built, not pulled")
    base = [
        line.split()[1]
        for line in (Path(context) / "Dockerfile").read_text().splitlines()
        if line.startswith("FROM ")
    ]
    require(
        len(base) == 1
        and base[0].startswith(f"{repository}:")
        and "@sha256:" in base[0]
        and ":latest" not in base[0],
        f"{name} base image must be a digest-pinned {repository} release",
    )

# Omeka code is immutable image content in both application containers. The
# two targets must use the exact same build inputs so nginx cannot serve stale
# assets after PHP is rebuilt with a new module, theme, or core release.
web_build = services["web"].get("build", {})
php_build = services["php"].get("build", {})
require(web_build.get("target") == "web", "web must use the Dockerfile web target")
require(php_build.get("target") == "runtime", "php must use the Dockerfile runtime target")
require(web_build.get("context") == php_build.get("context"), "web/php build contexts differ")
require(web_build.get("dockerfile") == php_build.get("dockerfile"), "web/php Dockerfiles differ")
require(web_build.get("args") == php_build.get("args"), "web/php immutable-code build args differ")
expected_modules_file = "deploy/amira/modules.txt" if is_amira else "_docker/empty-modules.txt"
require(
    web_build.get("args", {}).get("EXTRA_MODULES_FILE") == expected_modules_file,
    f"{variant} module manifest is not wired into both image builds",
)
# Deployment-specific code must stay out of the generic base image so partner
# deployments can build it unmodified.
expected_themes_file = (
    "deploy/amira/themes.txt" if is_amira else "_docker/empty-themes.txt"
)
require(
    web_build.get("args", {}).get("EXTRA_THEMES_FILE") == expected_themes_file,
    f"{variant} theme manifest is not wired into both image builds",
)

for name in ("web", "php"):
    require(
        not mounts_at(services[name], "/var/www/html"),
        f"{name} must not mask the immutable document root with a volume",
    )

web_media = mounts_at(services["web"], "/var/www/html/files")
php_media = mounts_at(services["php"], "/var/www/html/files")
php_logs = mounts_at(services["php"], "/var/www/html/logs")
php_config = mounts_at(services["php"], "/var/www/html/config/local.config.php")
require(len(web_media) == 1, "web must mount exactly one media volume")
require(len(php_media) == 1, "php must mount exactly one media volume")
require(len(php_logs) == 1, "php must mount exactly one logs volume")
require(len(php_config) == 1, "php must mount exactly one local.config.php")
if web_media and php_media:
    require(
        web_media[0].get("source") == php_media[0].get("source") == "omeka_media",
        "web/php media volume sources differ",
    )
    require(web_media[0].get("read_only") is True, "web media mount must be read-only")
    require(php_media[0].get("read_only") is not True, "php media mount must be writable")
if php_logs:
    require(php_logs[0].get("source") == "omeka_logs", "php logs must use omeka_logs")
    require(php_logs[0].get("read_only") is not True, "php logs mount must be writable")
if php_config:
    require(php_config[0].get("read_only") is True, "local.config.php must be read-only")

# Modules and themes are admin-managed volumes by default so EasyAdmin can
# install/update/remove them; compose.immutable.yml drops both volumes to make
# the image authoritative again. Neither mode may widen write access beyond
# these two directories.
extension_mounts = {
    "omeka_modules": "/var/www/html/modules",
    "omeka_themes": "/var/www/html/themes",
}
for source, target in extension_mounts.items():
    php_mounts = mounts_at(services["php"], target)
    web_mounts = mounts_at(services["web"], target)
    if is_immutable:
        require(
            not php_mounts and not web_mounts,
            f"{target} must be image content in the {variant} variant",
        )
        continue
    require(len(php_mounts) == 1, f"php must mount exactly one {source} volume")
    require(len(web_mounts) == 1, f"web must mount exactly one {source} volume")
    if php_mounts and web_mounts:
        require(
            php_mounts[0].get("source") == web_mounts[0].get("source") == source,
            f"php/web {source} volume sources differ",
        )
        require(
            php_mounts[0].get("read_only") is not True,
            f"php {source} mount must be writable so EasyAdmin can manage it",
        )
        require(
            web_mounts[0].get("read_only") is True,
            f"web {source} mount must be read-only",
        )
        require(
            (web_mounts[0].get("volume") or {}).get("nocopy") is True,
            f"web {source} mount must set nocopy so only php seeds the volume",
        )

# compose.immutable.yml replaces the php/web volume lists wholesale (Compose
# cannot delete a single mount during a merge). Listing it after a deployment
# overlay would silently discard that overlay's mounts, so assert the mounts
# every variant must keep regardless of ordering.
for target in (
    "/usr/local/etc/php/conf.d/uploads.ini",
    "/var/www/html/sideload",
    "/var/lib/php-sessions",
):
    require(
        len(mounts_at(services["php"], target)) == 1,
        f"php lost its {target} mount — check compose file ordering",
    )
for target in (
    "/etc/nginx/templates/default.conf.template",
    "/etc/nginx/templates/00-http-settings.conf.template",
    "/etc/nginx/templates/snippets/security-headers.conf.template",
):
    require(
        len(mounts_at(services["web"], target)) == 1,
        f"web lost its {target} mount — check compose file ordering",
    )
if is_amira:
    # The AMIRA overlay contributes these; they disappear if compose.immutable.yml
    # is layered after it instead of directly after the base stack.
    for target in (
        "/usr/local/share/omeka-vocabs/dre.rdf",
        "/usr/local/share/omeka-vocabs/dre.json",
    ):
        require(
            len(mounts_at(services["php"], target)) == 1,
            f"AMIRA vocabulary mount {target} is missing — list compose.immutable.yml"
            " directly after docker-compose.yml",
        )
    require(
        len(mounts_at(services["web"], "/etc/nginx/templates/extra-locations/mcp.conf.template")) == 1,
        "AMIRA /mcp nginx template is missing — list compose.immutable.yml"
        " directly after docker-compose.yml",
    )
    # Mounted with or without the curator profile: the location resolves its
    # upstream per request, so without the service it answers 502 instead of
    # stopping nginx from starting.
    require(
        len(mounts_at(services["web"], "/etc/nginx/templates/extra-locations/curator-mcp.conf.template")) == 1,
        "AMIRA /curator/mcp nginx template is missing — list compose.immutable.yml"
        " directly after docker-compose.yml",
    )
    # The /sparql location uses the zones from the http-level limits file and
    # proxies to the socket, so the three travel together.
    for target in (
        "/etc/nginx/templates/02-sparql.conf.template",
        "/etc/nginx/templates/extra-locations/sparql.conf.template",
        "/srv/sparql",
    ):
        require(
            len(mounts_at(services["web"], target)) == 1,
            f"AMIRA SPARQL mount {target} is missing — list compose.immutable.yml"
            " directly after docker-compose.yml",
        )
    # The /ontology/dre locations use variables from the http-level map, so
    # losing the map but keeping the locations would stop nginx from starting.
    for target in (
        "/etc/nginx/templates/01-dre-vocabulary.conf.template",
        "/etc/nginx/templates/extra-locations/dre-vocabulary.conf.template",
        "/srv/dre-vocabulary",
    ):
        require(
            len(mounts_at(services["web"], target)) == 1,
            f"AMIRA dre vocabulary mount {target} is missing — list compose.immutable.yml"
            " directly after docker-compose.yml",
        )

php_tmpfs = tmpfs_targets(services["php"])
for target in ("/tmp", "/run/omeka", "/run/php-fpm", "/var/www/.cache"):
    require(target in php_tmpfs, f"php writable tmpfs is missing: {target}")

expected_web_networks = {"frontend", "mcp", "curator"} if is_amira else {"frontend"}
require(
    set(services["web"].get("networks", {})) == expected_web_networks,
    "web network exposure changed",
)
require(
    set(services["php"].get("networks", {})) == {"frontend", "backend"},
    "php network exposure changed",
)
require(set(services["db"].get("networks", {})) == {"backend"}, "db network exposure changed")
require(set(services["typesense"].get("networks", {})) == {"backend"}, "typesense network exposure changed")
if is_amira:
    require(
        set(services["amira-mcp"].get("networks", {})) == {"mcp"},
        "amira-mcp network exposure changed",
    )
    # Oxigraph runs SPARQL SERVICE clauses as outbound HTTP requests and has
    # no switch to refuse them, so the endpoint must have no network at all:
    # on any Docker network a public query could aim them at Omeka or at the
    # host. nginx reaches it through a Unix socket on a shared volume instead.
    sparql = services["sparql"]
    require(sparql.get("network_mode") == "none", "sparql must run with network_mode: none")
    require(not sparql.get("networks"), "sparql must not join any network")
    sparql_media = mounts_at(sparql, "/media")
    require(
        len(sparql_media) == 1
        and sparql_media[0].get("source") == "omeka_media"
        and sparql_media[0].get("read_only") is True,
        "sparql must mount omeka_media read-only",
    )
    socket_mounts = [
        (mounts_at(services["web"], "/srv/sparql") or [{}])[0],
        (mounts_at(sparql, "/run/sparql") or [{}])[0],
    ]
    require(
        socket_mounts[0].get("source") == socket_mounts[1].get("source") == "sparql_socket",
        "web and sparql must share the sparql_socket volume",
    )
    require(socket_mounts[0].get("read_only") is True, "web sparql_socket mount must be read-only")

    mcp_context = str(services["amira-mcp"].get("build", {}).get("context", ""))
    require(
        re.search(r"#v\d+\.\d+\.\d+$", mcp_context) is not None,
        "amira-mcp must build from a release tag, not a floating branch",
    )

    # amira-mcp keys its per-minute rate limit on the TCP peer unless
    # AMIRA_TRUST_PROXY is set, which makes it take the key from
    # X-Forwarded-For instead. The header then *is* the rate-limit key, so the
    # two settings are one security decision: trusting it is only sound while
    # the /mcp location overwrites it with the single address this stack
    # resolved itself. Assert them together — enabling one without the other
    # either shares a single bucket across all visitors or hands out a
    # forgeable limit. (Which end of the chain upstream counts from has already
    # changed once — leftmost in v1.17.0, AMIRA_PROXY_HOPS from the right in
    # v1.19.0 — which is exactly why we send one entry rather than a chain.)
    # The curator service runs the same code behind /curator/mcp.
    check_forwarded_for("amira-mcp", "mcp.conf.template", "/mcp")
    check_node_heap("amira-mcp")
    if is_curator:
        check_forwarded_for("amira-mcp-curator", "curator-mcp.conf.template", "/curator/mcp")

if is_curator:
    # The curator service holds an Omeka key with view-all and caches private
    # records, so where each of those lives is part of the contract.
    curator = services["amira-mcp-curator"]
    require(
        set(curator.get("networks", {})) == {"curator"},
        "amira-mcp-curator must sit on its own curator network, shared only with web",
    )
    require(
        set(services["web"].get("networks", {})) >= {"curator"},
        "web must join the curator network to proxy /curator/mcp",
    )
    require("healthcheck" in curator, "amira-mcp-curator healthcheck is missing")
    curator_env = environment(curator)
    require(curator_env.get("AMIRA_ACCESS") == "curator", "amira-mcp-curator must set AMIRA_ACCESS=curator")
    # Links go to the public site; the keyed crawl stays inside the stack.
    site_base = curator_env.get("AMIRA_SITE_BASE", "")
    require(
        site_base.startswith("https://")
        and site_base == environment(services["amira-mcp"]).get("AMIRA_SITE_BASE"),
        "amira-mcp-curator AMIRA_SITE_BASE must be the public https site, the same as"
        " amira-mcp's, so the links it returns open for curators",
    )
    api_base = urlsplit(curator_env.get("AMIRA_API_BASE", ""))
    require(
        api_base.scheme == "http"
        and api_base.hostname == "web"
        and api_base.path.rstrip("/").endswith("/api"),
        "amira-mcp-curator must crawl Omeka over the internal network"
        " (AMIRA_API_BASE=http://web/api), never the public host, so requests"
        " carrying the Omeka key never leave the stack",
    )
    for name in ("AMIRA_MCP_BEARER_TOKEN", "AMIRA_MCP_TOKEN_FILE"):
        require(name not in curator_env, f"amira-mcp-curator must not set {name}; it uses personal tokens")
    curator_mounts = [mount for mount in curator.get("volumes", []) if isinstance(mount, dict)]
    require(
        all(mount.get("type") == "bind" for mount in curator_mounts),
        "amira-mcp-curator must not mount a volume: its cache holds private data and belongs on tmpfs",
    )
    for name in ("AMIRA_OMEKA_KEY_FILE", "AMIRA_MCP_TOKENS_FILE"):
        path = curator_env.get(name, "")
        holders = [
            mount
            for mount in curator_mounts
            if path.startswith(str(mount.get("target", "")).rstrip("/") + "/")
        ]
        require(bool(path) and len(holders) == 1, f"amira-mcp-curator {name} must come from one mount")
        for mount in holders:
            require(mount.get("read_only") is True, f"amira-mcp-curator {name} mount must be read-only")
            require(
                (mount.get("bind") or {}).get("create_host_path") is False,
                f"amira-mcp-curator {name} mount must not create a missing host directory",
            )
    cache_dir = curator_env.get("AMIRA_CACHE_DIR", "")
    require(
        any(
            cache_dir == target or cache_dir.startswith(target.rstrip("/") + "/")
            for target in tmpfs_targets(curator)
        ),
        "amira-mcp-curator AMIRA_CACHE_DIR must be on a tmpfs",
    )
    require(bool(limits(curator).get("memory")), "amira-mcp-curator must have a memory limit")
    check_node_heap("amira-mcp-curator")
    # Same code as amira-mcp, at a ref of its own until curator mode is
    # released: a branch or commit is allowed here, unlike for amira-mcp.
    curator_repo, _, curator_ref = str(curator.get("build", {}).get("context", "")).partition("#")
    require(
        curator_repo == mcp_context.partition("#")[0] and bool(curator_ref),
        "amira-mcp-curator must build from the amira-mcp repository at an explicit ref",
    )


# --- File-based secrets (compose.secrets.yml) ---------------------------------
# Each secret and the services allowed to read it. Nothing else may mount it.
SECRET_READERS = {
    "mysql_password": {"php", "db"},
    "omeka_secret_key": {"php"},
    "typesense_api_key": {"php", "typesense"},
    "omeka_admin_password": {"php"},
}
# The plain variable each secret replaces.
SECRET_VARIABLES = {name.upper(): name for name in SECRET_READERS}


def service_secrets(service: dict[str, Any]) -> dict[str, str]:
    """source -> target of a service's secrets, with Compose's default target."""
    result: dict[str, str] = {}
    for entry in service.get("secrets") or []:
        if isinstance(entry, str):
            result[entry] = f"/run/secrets/{entry}"
        else:
            source = str(entry.get("source", ""))
            target = str(entry.get("target") or source)
            result[source] = target if target.startswith("/") else f"/run/secrets/{target}"
    return result


def check_secrets() -> None:
    top_level = config.get("secrets") or {}
    # The db healthcheck must work whichever way the password arrives, so it
    # is checked in every mode: it has to read MYSQL_PASSWORD_FILE when set
    # and must not require MYSQL_PASSWORD.
    healthcheck = " ".join(str(part) for part in (services["db"].get("healthcheck") or {}).get("test") or [])
    require(
        "MYSQL_PASSWORD_FILE" in healthcheck and "MYSQL_PASSWORD:-" in healthcheck.replace("$$", "$"),
        "the db healthcheck must read MYSQL_PASSWORD_FILE when set and not require MYSQL_PASSWORD",
    )
    if not is_secrets:
        # The default stays exactly the .env-based setup.
        require(not top_level, f"{variant} must not define secrets (that is compose.secrets.yml's job)")
        for name, service in services.items():
            service_env = environment(service)
            require(not service.get("secrets"), f"{name} must not use secrets outside compose.secrets.yml")
            for variable in SECRET_VARIABLES:
                require(
                    f"{variable}_FILE" not in service_env,
                    f"{name} must not set {variable}_FILE outside compose.secrets.yml",
                )
        require(
            not environment(services["php"]).get("MYSQL_PASSWORD", "").startswith("compose.secrets.yml-is-not-loaded:"),
            "MYSQL_PASSWORD resolved to the compose.secrets.yml marker: set MYSQL_PASSWORD for this check",
        )
        return

    for secret, readers in SECRET_READERS.items():
        definition = top_level.get(secret) or {}
        source = str(definition.get("file", ""))
        require(
            bool(source) and Path(source).name == secret and not definition.get("environment"),
            f"secret {secret} must come from the file {secret} in SECRETS_DIR",
        )
        users = {name for name, service in services.items() if secret in service_secrets(service)}
        require(users == readers, f"secret {secret} must be mounted into exactly {sorted(readers)}, not {sorted(users)}")
    for name, service in services.items():
        service_env = environment(service)
        mounted = service_secrets(service)
        # No plain value may reach any container configuration, not even empty.
        for variable in SECRET_VARIABLES:
            require(variable not in service_env, f"{name} must not receive {variable} in secrets mode")
        # Every *_FILE a service reads must point under /run/secrets, and the
        # four replaced variables at exactly their own mounted secret.
        for key, value in service_env.items():
            if not key.endswith("_FILE"):
                continue
            require(value.startswith("/run/secrets/"), f"{name} {key} must point under /run/secrets/")
            secret = SECRET_VARIABLES.get(key.removesuffix("_FILE"))
            if secret:
                require(
                    mounted.get(secret) == value == f"/run/secrets/{secret}",
                    f"{name} {key} must be /run/secrets/{secret}, mounted from the {secret} secret",
                )
        for secret in mounted:
            if secret in SECRET_READERS:
                require(
                    f"{secret.upper()}_FILE" in service_env,
                    f"{name} mounts the {secret} secret but does not set {secret.upper()}_FILE",
                )
    php_env = environment(services["php"])
    for variable in SECRET_VARIABLES:
        require(f"{variable}_FILE" in php_env, f"php must read {variable}_FILE in secrets mode")
    require(
        "OMEKA_SECRETS_ALSO_IN_ENV" in php_env and not php_env["OMEKA_SECRETS_ALSO_IN_ENV"].strip(),
        "secrets mode: these are still set in the environment/.env and would be ignored: "
        + php_env.get("OMEKA_SECRETS_ALSO_IN_ENV", "(marker missing)"),
    )


check_secrets()


# --- Bundled TLS (compose.tls.yml) --------------------------------------------
CADDY_IMAGE = re.compile(r"^caddy:2\.[0-9.]+@sha256:[0-9a-f]{64}$")
CADDY_PORTS = {(80, "80", "tcp"), (443, "443", "tcp"), (443, "443", "udp")}


def check_tls() -> None:
    caddy = services.get("caddy")
    if caddy is None:
        return  # reported above; nothing else to check
    # The internet-facing edge: pinned, unprivileged, contained.
    require(
        CADDY_IMAGE.fullmatch(str(caddy.get("image", ""))) is not None,
        "caddy image must be an exact caddy:2.x release pinned by digest",
    )
    require(caddy.get("cap_drop") == ["ALL"], "caddy must drop exactly ALL capabilities")
    require(not caddy.get("cap_add"), "caddy must not add capabilities")
    require(
        "no-new-privileges:true" in (caddy.get("security_opt") or []),
        "caddy must set no-new-privileges",
    )
    require(caddy.get("read_only") is True, "caddy root filesystem must be read-only")
    # Binding 80/443 without CAP_NET_BIND_SERVICE relies on this namespaced
    # sysctl; without it Caddy cannot start.
    require(
        str((caddy.get("sysctls") or {}).get("net.ipv4.ip_unprivileged_port_start")) == "80",
        "caddy must set net.ipv4.ip_unprivileged_port_start=80 (it has no capabilities)",
    )
    # Root without capabilities, by design: the image's /data and /config are
    # root-owned, and another user could not write the certificates.
    require("user" not in caddy, "caddy must not override its user (see compose.tls.yml)")
    require("/tmp" in tmpfs_targets(caddy), "caddy needs a /tmp tmpfs on its read-only root")
    caddy_limits = limits(caddy)
    for key in ("cpus", "memory", "pids"):
        require(bool(caddy_limits.get(key)), f"caddy must set deploy.resources.limits.{key}")
    require(not caddy.get("pids_limit"), "caddy must set its pids limit in deploy.resources only")
    require("healthcheck" in caddy, "caddy healthcheck is missing")
    logging = caddy.get("logging") or {}
    require(
        logging.get("driver") == "json-file"
        and bool((logging.get("options") or {}).get("max-size"))
        and bool((logging.get("options") or {}).get("max-file")),
        "caddy must use rotated json-file logging (max-size and max-file)",
    )
    require(caddy.get("restart") == "unless-stopped", "caddy restart policy changed")
    require("web" in (caddy.get("depends_on") or {}), "caddy must depend on web")
    require(set(caddy.get("networks") or {}) == {"frontend"}, "caddy must sit on the frontend network only")

    caddyfile = mounts_at(caddy, "/etc/caddy/Caddyfile")
    require(
        len(caddyfile) == 1
        and caddyfile[0].get("type") == "bind"
        and caddyfile[0].get("read_only") is True
        and str(caddyfile[0].get("source", "")).endswith("_docker/caddy/Caddyfile"),
        "caddy must bind-mount _docker/caddy/Caddyfile read-only at /etc/caddy/Caddyfile",
    )
    top_volumes = config.get("volumes") or {}
    for source, target in (("caddy_data", "/data"), ("caddy_config", "/config")):
        mount = mounts_at(caddy, target)
        require(
            len(mount) == 1 and mount[0].get("type") == "volume" and mount[0].get("source") == source,
            f"caddy must mount the {source} volume at {target}",
        )
        require(source in top_volumes, f"the {source} volume must be defined at top level")

    ports = {
        (port.get("target"), str(port.get("published")), port.get("protocol", "tcp"))
        for port in caddy.get("ports") or []
        if isinstance(port, dict)
    }
    require(
        ports == CADDY_PORTS and len(caddy.get("ports") or []) == len(CADDY_PORTS),
        "caddy must publish exactly 80/tcp, 443/tcp and 443/udp on the same host ports",
    )

    caddy_env = environment(caddy)
    server_name = caddy_env.get("SERVER_NAME", "").strip()
    # nginx's "_" catch-all would make Caddy request a certificate for "_".
    require(bool(server_name) and server_name != "_", "caddy SERVER_NAME must be the public name, not empty or _")
    require(caddy_env.get("ACME_CA", "").startswith("https://"), "caddy ACME_CA must be an https:// URL")
    require(caddy_env.get("CADDY_TLS") in {"acme", "internal"}, "CADDY_TLS must be acme or internal")
    require(
        re.fullmatch(r"\d+", caddy_env.get("CADDY_HSTS_MAX_AGE", "")) is not None,
        "CADDY_HSTS_MAX_AGE must be a whole number of seconds",
    )
    # HTTPS-only behind Caddy: Secure cookie by default. HSTS comes from
    # Caddy, so nginx's own header stays off rather than doubling it.
    require(
        environment(services["php"]).get("OMEKA_SESSION_COOKIE_SECURE") == "true",
        "compose.tls.yml must default OMEKA_SESSION_COOKIE_SECURE to true",
    )
    require(
        environment(services["web"]).get("NGINX_HSTS_MAX_AGE") == "0",
        "with compose.tls.yml NGINX_HSTS_MAX_AGE must stay 0 (Caddy sends HSTS)",
    )


if is_tls:
    check_tls()
else:
    require(
        not any(name in (config.get("volumes") or {}) for name in ("caddy_data", "caddy_config")),
        "caddy volumes must come from compose.tls.yml only",
    )

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Compose security contract passed ({variant}{'-secrets' if is_secrets else ''}{'-tls' if is_tls else ''}).")
