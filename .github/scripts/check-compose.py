#!/usr/bin/env python3
"""Assert security and wiring invariants on `docker compose config --format json`."""

from __future__ import annotations

import json
import os
import re
import sys
from typing import Any


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


variant = sys.argv[1] if len(sys.argv) > 1 else "base"
if variant not in {"base", "amira", "immutable", "amira-immutable"}:
    raise SystemExit("usage: check-compose.py base|amira|immutable|amira-immutable")

# Modules/themes are admin-managed volumes by default; compose.immutable.yml
# drops them back into the image layer.
is_amira = variant in {"amira", "amira-immutable"}
is_immutable = variant in {"immutable", "amira-immutable"}

config = json.load(sys.stdin)
services: dict[str, dict[str, Any]] = config.get("services", {})
errors: list[str] = []

expected_services = {"web", "php", "db", "typesense"}
if is_amira:
    expected_services.add("amira-mcp")
missing_services = expected_services - services.keys()
require(not missing_services, f"required services are missing: {', '.join(sorted(missing_services))}")
require(("amira-mcp" in services) == is_amira, "AMIRA overlay service mismatch")

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
    require(
        services["amira-mcp"].get("read_only") is True,
        "amira-mcp root filesystem must be read-only",
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
        "/usr/local/share/omeka-vocabs/dre.owl",
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

php_tmpfs = tmpfs_targets(services["php"])
for target in ("/tmp", "/run/omeka", "/run/php-fpm", "/var/www/.cache"):
    require(target in php_tmpfs, f"php writable tmpfs is missing: {target}")

expected_web_networks = {"frontend", "mcp"} if is_amira else {"frontend"}
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
    mcp_context = str(services["amira-mcp"].get("build", {}).get("context", ""))
    require(
        re.search(r"#v\d+\.\d+\.\d+$", mcp_context) is not None,
        "amira-mcp must build from a release tag, not a floating branch",
    )

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Compose security contract passed ({variant}).")
