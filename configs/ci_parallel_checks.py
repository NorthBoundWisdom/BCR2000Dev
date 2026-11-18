#!/usr/bin/env python3
"""Run independent suites concurrently and real-clock transport checks serially, retaining all outcomes."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def execute(specs, directory, runner=subprocess.run, clock=time.perf_counter, workers=3):
    directory.mkdir(parents=True, exist_ok=True)
    if len({name for name, _ in specs}) != len(specs):
        raise ValueError("Check names must be unique")

    def one(spec):
        name, command = spec
        start = clock()
        path = directory / (name + ".log")
        with path.open("w") as log:
            try:
                result = runner(command, stdout=log, stderr=subprocess.STDOUT)
                returncode = result.returncode
            except OSError as error:
                log.write(str(error) + "\n")
                returncode = 127
        row = {
            "name": name,
            "command": command,
            "returncode": returncode,
            "seconds": round(clock() - start, 3),
            "log": str(path),
        }
        print(json.dumps(row), flush=True)
        if returncode:
            print(path.read_text(), flush=True)
        return row

    with ThreadPoolExecutor(max_workers=workers) as pool:
        rows = list(pool.map(one, specs))
    (directory / "timing.json").write_text(json.dumps(rows, indent=2) + "\n")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=["tests", "transports"])
    parser.add_argument("--native-precompiled", action="store_true")
    args = parser.parse_args()
    if args.native_precompiled and args.group != "tests":
        parser.error("Precompiled discovery applies only to the native test group")
    py = sys.executable
    if args.group == "tests":
        specs = [
            ("python-workflows", [py, "configs/run_python_workflow_tests.py"]),
            (
                "native-suites",
                [py, "configs/macos_workflow.py", "test"]
                + (["--precompiled-tests"] if args.native_precompiled else []),
            ),
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
        ]
    rows = execute(specs, Path("build/ci-verification") / args.group, workers=3 if args.group == "tests" else 1)
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
