#!/usr/bin/env python3
"""Generate an Ansible inventory file from Terraform output.

This is integration pattern #1 from Day 15: Terraform stays the source of truth
about *what exists*, Ansible stays the source of truth about *how it is
configured*, and this script is the 60 lines that connect them.

Usage
-----
    # from terraform/environments/dev, after an apply
    ./../../scripts/tf_to_inventory.py -o ../../../ansible/inventory/generated/servers.yml

    # dry run - print the inventory instead of writing it
    ./../../scripts/tf_to_inventory.py --stdout

    # read a state file directly instead of shelling out to terraform
    ./../../scripts/tf_to_inventory.py --state-file ../../../labs/local/sample.tfstate.json --stdout

Exit codes: 0 ok, 1 usage/IO error, 2 terraform failure, 3 empty inventory.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("PyYAML is required: pip install pyyaml\n")
    raise SystemExit(1)

HEADER = """# GENERATED FILE - DO NOT EDIT BY HAND.
# Source : terraform output ansible_inventory_json
# Regenerate:
#   terraform/scripts/tf_to_inventory.py -o ansible/inventory/generated/servers.yml
# Any manual edit here is lost on the next run. Put permanent host variables in
# ansible/inventory/group_vars/ instead.
---
"""


def find_cli() -> str:
    """Prefer terraform, fall back to tofu (the open-source fork)."""
    for candidate in ("terraform", "tofu"):
        if shutil.which(candidate):
            return candidate
    raise SystemExit("neither 'terraform' nor 'tofu' is on PATH")


def inventory_from_terraform(workdir: pathlib.Path, output_name: str) -> dict:
    cli = find_cli()
    cmd = [cli, "output", "-json", output_name]
    try:
        proc = subprocess.run(
            cmd, cwd=workdir, capture_output=True, text=True, check=False
        )
    except OSError as exc:  # pragma: no cover
        raise SystemExit(f"failed to run {cli}: {exc}")

    if proc.returncode != 0:
        sys.stderr.write(proc.stderr or f"{cli} output failed\n")
        raise SystemExit(2)

    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{cli} did not return JSON: {exc}")


def inventory_from_state(state_path: pathlib.Path, output_name: str) -> dict:
    """Read the inventory straight out of a terraform.tfstate file.

    Useful in CI where the state is an artifact, and in Day 15's comparison of
    "shell out to terraform" vs "parse the state".
    """
    with state_path.open("r", encoding="utf-8") as handle:
        state = json.load(handle)

    outputs = state.get("outputs", {})
    if output_name not in outputs:
        raise SystemExit(
            f"output '{output_name}' not found in {state_path}. "
            f"Available: {', '.join(sorted(outputs)) or '(none)'}"
        )
    return outputs[output_name].get("value", {})


def count_hosts(inventory: dict) -> int:
    total = 0
    for group in inventory.get("all", {}).get("children", {}).values():
        if not group:
            continue
        total += len(group.get("hosts") or {})
        for child in (group.get("children") or {}).values():
            # `children: {servers: null}` is a group reference, not a definition.
            if not child:
                continue
            total += len(child.get("hosts") or {})
    return total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "-o", "--output", type=pathlib.Path,
        help="path to write the inventory YAML",
    )
    parser.add_argument("--stdout", action="store_true", help="print instead of writing")
    parser.add_argument(
        "-w", "--workdir", type=pathlib.Path, default=pathlib.Path("."),
        help="terraform working directory (default: cwd)",
    )
    parser.add_argument(
        "-n", "--output-name", default="ansible_inventory_json",
        help="terraform output name (default: ansible_inventory_json)",
    )
    parser.add_argument(
        "-s", "--state-file", type=pathlib.Path,
        help="read from this terraform.tfstate instead of running terraform",
    )
    args = parser.parse_args()

    if args.state_file:
        inventory = inventory_from_state(args.state_file, args.output_name)
    else:
        inventory = inventory_from_terraform(args.workdir, args.output_name)

    if not inventory:
        sys.stderr.write("terraform returned an empty inventory\n")
        return 3

    rendered = HEADER + yaml.safe_dump(inventory, sort_keys=False, default_flow_style=False)
    hosts = count_hosts(inventory)

    if args.stdout or not args.output:
        sys.stdout.write(rendered)
        sys.stderr.write(f"\n# {hosts} host(s)\n")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")
    sys.stderr.write(f"wrote {args.output} ({hosts} host(s))\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
