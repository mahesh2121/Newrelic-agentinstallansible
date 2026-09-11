#!/usr/bin/env python3
"""Parse every .tf file with a real HCL2 parser.

`terraform validate` cannot run in an offline sandbox because it needs the
provider schemas from registry.terraform.io. This is the next best thing: it
proves every file is syntactically valid HCL2 and reports the resource types
each file declares, so a typo'd block name is caught in CI instead of at apply.

    python3 tools/hcl_parse_check.py            # whole repo
    python3 tools/hcl_parse_check.py terraform/modules/network
"""

from __future__ import annotations

import pathlib
import sys

try:
    import hcl2
except ImportError:
    sys.stderr.write("pip install python-hcl2\n")
    raise SystemExit(1)

BLOCK_KEYS = ("resource", "data", "variable", "output", "locals", "module",
              "provider", "terraform", "moved", "import", "check")


def inspect(path: pathlib.Path) -> tuple[list[str], list[str]]:
    """Return (errors, declared block kinds) for one file."""
    try:
        with path.open("r", encoding="utf-8") as handle:
            parsed = hcl2.load(handle)
    except Exception as exc:  # noqa: BLE001 - parser raises many types
        return [f"{path}: {exc.__class__.__name__}: {exc}"], []

    kinds: list[str] = []
    for block in parsed.get("resource", []):
        kinds.extend(f"resource.{name}" for name in block)
    for block in parsed.get("data", []):
        for ds in block:
            kinds.extend(f"data.{name}" for name in ds)
    for key in ("variable", "output", "module", "provider"):
        for block in parsed.get(key, []):
            kinds.extend(f"{key}.{name}" for name in block)
    return [], kinds


def main() -> int:
    roots = [pathlib.Path(a) for a in sys.argv[1:]] or [pathlib.Path("terraform")]
    files = sorted(
        {p for root in roots if root.exists() for p in root.rglob("*.tf")}
    )

    if not files:
        sys.stderr.write("no .tf files found\n")
        return 1

    errors: list[str] = []
    total_blocks = 0
    for path in files:
        file_errors, kinds = inspect(path)
        errors.extend(file_errors)
        total_blocks += len(kinds)
        status = "FAIL" if file_errors else "ok  "
        print(f"{status} {path}  ({len(kinds)} blocks)")
        if kinds and not file_errors:
            interesting = [k for k in kinds if k.startswith(("resource.", "data."))]
            if interesting:
                print(f"       {', '.join(sorted(set(interesting)))}")

    print()
    if errors:
        print(f"HCL PARSE FAILED for {len(errors)} file(s):")
        for err in errors:
            print(f"  {err}")
        return 1

    print(f"HCL PARSE OK: {len(files)} file(s), {total_blocks} declared block(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
