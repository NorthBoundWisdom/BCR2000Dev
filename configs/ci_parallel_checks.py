#!/usr/bin/env python3
"""Run independent CI checks concurrently, retaining every command, outcome and duration."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def execute(specs, directory, runner=subprocess.run, clock=time.perf_counter):
    directory.mkdir(parents=True, exist_ok=True)
    if len({name for name, _ in specs}) != len(specs):
        raise ValueError("Check names must be unique")

    def one(spec):
        name, command = spec
        start = clock()
        path = directory / (name + ".log")
        with path.open("w") as log:
            result = runner(command, stdout=log, stderr=subprocess.STDOUT)
        row = {
            "name": name,
            "command": command,
            "returncode": result.returncode,
            "seconds": round(clock() - start, 3),
            "log": str(path),
        }
        print(json.dumps(row), flush=True)
        if result.returncode:
            print(path.read_text(), flush=True)
        return row

    with ThreadPoolExecutor(max_workers=3) as pool:
        rows = list(pool.map(one, specs))
    (directory / "timing.json").write_text(json.dumps(rows, indent=2) + "\n")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=["tests", "transports"])
    args = parser.parse_args()
    py = sys.executable
    if args.group == "tests":
        specs = [
            ("python-workflows", [py, "-m", "unittest", "discover", "-s", "Tests/BuildWorkflowTests", "-v"]),
            ("native-suites", [py, "configs/macos_workflow.py", "test"]),
        ]
    else:
        binary = "build/ci-surface-provider/BCRProviderService"
        specs = [
            (
                "surface",
                [
                    py,
                    "configs/verify_surface_control_transport.py",
                    "--artifact",
                    "build/ci-surface-provider",
                    "--output",
                    "build/ci-surface-transport",
                ],
            ),
            (
                "clients",
                [
                    py,
                    "configs/verify_surface_clients_transport.py",
                    "--binary",
                    binary,
                    "--output",
                    "build/ci-surface-client-roles",
                ],
            ),
            (
                "hardware-doubles",
                [
                    py,
                    "configs/verify_hardware_surface_transport.py",
                    "--binary",
                    binary,
                    "--output",
                    "build/ci-surface-hardware-roles",
                    "--scoped-clients",
                ],
            ),
            (
                "display-budget",
                [py, "configs/verify_display_budget.py", "--binary", binary, "--output", "build/ci-display-budget"],
            ),
            (
                "multiple-displays",
                [
                    py,
                    "configs/verify_multiple_display_clients.py",
                    "--binary",
                    binary,
                    "--output",
                    "build/ci-multiple-displays",
                ],
            ),
            (
                "status-demo",
                [
                    py,
                    "build/ci-surface-provider/diagnostics/verify_status_panel_demo.py",
                    "--artifact",
                    "build/ci-surface-provider",
                    "--output",
                    "build/ci-status-panel-demo",
                ],
            ),
        ]
    rows = execute(specs, Path("build/ci-verification") / args.group)
    import os

    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(path).open("a") as summary:
            summary.write(
                "\n### Independent checks: " + args.group + "\n\n| Check | Exit | Seconds |\n| --- | ---: | ---: |\n"
            )
            summary.writelines(f"| {row['name']} | {row['returncode']} | {row['seconds']} |\n" for row in rows)
    if any(row["returncode"] for row in rows):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
