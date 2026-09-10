#!/usr/bin/env python3
"""Ansible dynamic inventory backed by terraform.tfstate.

Integration pattern #2 from Day 15. Unlike tf_to_inventory.py there is no
intermediate file to go stale: Ansible reads the state on every run.

Point Ansible directly at this script - the ansible.builtin.script inventory
plugin loads the executable itself (its verify_file() requires os.X_OK), there
is no YAML wrapper file:

    export TF_STATE_FILE=../../labs/local/sample.tfstate.json
    chmod +x inventory/terraform.py
    ansible-inventory -i inventory/terraform.py --graph
    ansible servers -i inventory/terraform.py -m ping

Environment variables:
    TF_STATE_FILE   path to terraform.tfstate (default terraform/environments/dev/terraform.tfstate)
    TF_OUTPUT_NAME  terraform output to read (default ansible_inventory_json)

Supports the two calls Ansible makes:
    terraform.py --list           -> full inventory JSON
    terraform.py --host <name>    -> host variables JSON
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

STATE_PATH = pathlib.Path(
    os.environ.get("TF_STATE_FILE", "terraform/environments/dev/terraform.tfstate")
)
OUTPUT_NAME = os.environ.get("TF_OUTPUT_NAME", "ansible_inventory_json")


def load_state(path: pathlib.Path) -> dict:
    if not path.exists():
        sys.stderr.write(
            f"state file not found: {path}\n"
            "set TF_STATE_FILE to the location of your terraform.tfstate\n"
        )
        return {}
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def to_dynamic_format(tree: dict) -> dict:
    """Convert Ansible's nested inventory shape to dynamic-inventory JSON."""
    result: dict = {"_meta": {"hostvars": {}}, "all": {"children": [], "hosts": []}}

    def walk(node: dict, group_name: str) -> None:
        group = result.setdefault(group_name, {"children": [], "hosts": []})
        for host, hostvars in (node.get("hosts") or {}).items():
            if host not in group["hosts"]:
                group["hosts"].append(host)
            result["_meta"]["hostvars"].setdefault(host, {}).update(hostvars or {})
        for child_name, child_node in (node.get("children") or {}).items():
            if child_node is None:
                # `children: {servers: null}` is YAML for "reference an existing
                # group" - register the membership without redefining it.
                if child_name not in group["children"]:
                    group["children"].append(child_name)
                continue
            if child_name not in group["children"]:
                group["children"].append(child_name)
            walk(child_node, child_name)
        for key, value in (node.get("vars") or {}).items():
            result.setdefault(group_name, {}).setdefault("vars", {})[key] = value

    root = tree.get("all", {})
    for host, hostvars in (root.get("hosts") or {}).items():
        result["all"]["hosts"].append(host)
        result["_meta"]["hostvars"][host] = hostvars or {}
    for group_name, group_node in (root.get("children") or {}).items():
        if group_node is None:
            continue
        if group_name not in result["all"]["children"]:
            result["all"]["children"].append(group_name)
        walk(group_node, group_name)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--host")
    args = parser.parse_args()

    state = load_state(STATE_PATH)
    value = state.get("outputs", {}).get(OUTPUT_NAME, {}).get("value", {})
    inventory = to_dynamic_format(value)

    if args.host:
        json.dump(inventory["_meta"]["hostvars"].get(args.host, {}), sys.stdout, indent=2)
    else:
        json.dump(inventory, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
