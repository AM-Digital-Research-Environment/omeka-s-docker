#!/usr/bin/env python3
"""Assert security and wiring invariants on `docker compose config --format json`."""

from __future__ import annotations

import json
import os
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


variant = sys.argv[1] if len(sys.argv) > 1 else "base"
if variant not in {"base", "amira"}:
    raise SystemExit("usage: check-compose.py base|amira")

config = json.load(sys.stdin)
services: dict[str, dict[str, Any]] = config.get("services", {})
errors: list[str] = []

expected_services = {"web", "php", "db", "typesense"}
if variant == "amira":
    expected_services.add("amira-mcp")
missing_services = expected_services - services.keys()
require(not missing_services, f"required services are missing: {', '.join(sorted(missing_services))}")
require(("amira-mcp" in services) == (variant == "amira"), "AMIRA overlay service mismatch")

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

for name in ("web", "typesense"):
    require(services[name].get("read_only") is True, f"{name} root filesystem must be read-only")
if variant == "amira":
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

for name in ("web", "db", "typesense"):
    image = str(services[name].get("image", ""))
    require("@sha256:" in image, f"{name} image must be digest-pinned")
    require(":latest" not in image, f"{name} image must not use latest")

expected_web_networks = {"frontend", "mcp"} if variant == "amira" else {"frontend"}
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
if variant == "amira":
    require(
        set(services["amira-mcp"].get("networks", {})) == {"mcp"},
        "amira-mcp network exposure changed",
    )

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Compose security contract passed ({variant}).")
