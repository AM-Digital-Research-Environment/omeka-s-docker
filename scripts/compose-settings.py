#!/usr/bin/env python3
"""Read selected non-secret settings from rendered Compose JSON on stdin."""
import json
import re
import sys


def resolve(config, args):
    command, *values = args
    if command == "project":
        name = config.get("name", "")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name):
            raise ValueError("Invalid Compose project name")
        return [name]
    if command == "volume":
        service, target = values
        mounts = [m for m in config["services"].get(service, {}).get("volumes", [])
                  if m.get("target") == target]
        if not mounts:
            return [""]
        if len(mounts) != 1 or mounts[0].get("type") != "volume":
            raise ValueError(f"{service}:{target} must use a named volume for these backup/restore helpers")
        definition = config.get("volumes", {}).get(mounts[0]["source"], {})
        if not definition.get("external") and (definition.get("driver", "local") != "local" or definition.get("driver_opts")):
            raise ValueError("Provision custom storage separately as an external volume before using these helpers")
        name = definition.get("name", "")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name):
            raise ValueError(f"Cannot resolve Docker volume for {service}:{target}")
        return [name]
    if command == "external":
        return ["1" if any(v.get("name") == values[0] and v.get("external")
                           for v in config.get("volumes", {}).values()) else "0"]
    if command == "manifests":
        build = config["services"]["php"].get("build", {})
        settings = build.get("args", {})
        paths = ["_docker/default-modules.txt", "_docker/extra-modules.txt",
                 "_docker/extra-themes.txt", settings.get("EXTRA_MODULES_FILE"),
                 settings.get("EXTRA_THEMES_FILE")]
        return list(dict.fromkeys(p for p in paths if p))
    raise ValueError(f"Unknown setting: {command}")


if __name__ == "__main__":
    try:
        for value in resolve(json.load(sys.stdin), sys.argv[1:]):
            print(value)
    except (ValueError, KeyError, TypeError) as error:
        sys.exit(f"ERROR: {error}")
