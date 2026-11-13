#!/usr/bin/env python3
"""Assert security and wiring invariants on `docker compose config --format json`."""

from __future__ import annotations

import json
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
if variant not in {"base", "amira", "amira-curator", "immutable", "amira-immutable"}:
    raise SystemExit("usage: check-compose.py base|amira|amira-curator|immutable|amira-immutable")

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
missing_services = expected_services - services.keys()
require(not missing_services, f"required services are missing: {', '.join(sorted(missing_services))}")
require(("amira-mcp" in services) == is_amira, "AMIRA overlay service mismatch")
# The curator service serves private data, so it stays behind its profile:
# present when the profile is asked for, never by default.
require(
    ("amira-mcp-curator" in services) == is_curator,
    "amira-mcp-curator must start only with the curator profile",
)

if missing_services:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

if not errors:
    php_env = environment(services["php"])
    db_env = environment(services["db"])
    for name in ("MYSQL_DATABASE", "MYSQL_USER", "MYSQL_PASSWORD"):
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
    if name != "web":
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

for name in ("web", "php", "typesense"):
    require(services[name].get("read_only") is True, f"{name} root filesystem must be read-only")
if is_amira:
    for name in ("amira-mcp", "sparql", *(("amira-mcp-curator",) if is_curator else ())):
        require(
            services[name].get("read_only") is True,
            f"{name} root filesystem must be read-only",
        )

web_ports = services["web"].get("ports", [])
require(len(web_ports) == 1, "web must publish exactly one port")
if web_ports and isinstance(web_ports[0], dict):
    require(web_ports[0].get("host_ip") == "127.0.0.1", "web must bind to loopback by default")

for name in ("web", "php", "db", "typesense"):
    require("healthcheck" in services[name], f"{name} healthcheck is missing")

for name in ("db", "typesense"):
    image = str(services[name].get("image", ""))
    require("@sha256:" in image, f"{name} image must be digest-pinned")
    require(":latest" not in image, f"{name} image must not use latest")

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
    limits = ((curator.get("deploy") or {}).get("resources") or {}).get("limits") or {}
    require(bool(limits.get("memory")), "amira-mcp-curator must have a memory limit")
    # Same code as amira-mcp, at a ref of its own until curator mode is
    # released: a branch or commit is allowed here, unlike for amira-mcp.
    curator_repo, _, curator_ref = str(curator.get("build", {}).get("context", "")).partition("#")
    require(
        curator_repo == mcp_context.partition("#")[0] and bool(curator_ref),
        "amira-mcp-curator must build from the amira-mcp repository at an explicit ref",
    )

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Compose security contract passed ({variant}).")
