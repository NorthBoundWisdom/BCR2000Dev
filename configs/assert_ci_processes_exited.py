#!/usr/bin/env python3
"""Fail before timed acceptance if a native product/test process is still running; never kill it."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

PRODUCTS = frozenset({"BCRAgentConsole", "BCRProviderService", "BCRProfileTool", "xctest"})


def live_products(process_table: str) -> list[dict[str, object]]:
    found = []
    for line in process_table.splitlines():
        if not line.strip():
            continue
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) <= 0:
            raise ValueError("Cannot validate native process exit: malformed PID/comm data")
        pid, command = int(fields[0]), fields[1]
        name = Path(command).name
        if name in PRODUCTS or name.endswith(".xctest"):
            found.append({"pid": pid, "executable": command})
    if not process_table.strip():
        raise ValueError("Cannot validate native process exit: empty process inventory")
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        # comm contains the executable name only. Never read or log process arguments/credentials.
        result = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True)
        products = live_products(result.stdout)
        record = {"native_products_exited": not products, "live_products": products}
    except (OSError, subprocess.CalledProcessError, ValueError):
        record = {"native_products_exited": False, "error": "cannot_verify_native_process_exit"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record))
    return 0 if record["native_products_exited"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
