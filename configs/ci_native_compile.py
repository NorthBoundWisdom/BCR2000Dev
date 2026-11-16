#!/usr/bin/env python3
"""Compile native tests and the original audit helpers concurrently; run no product or GUI."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from configs.ci_parallel_checks import execute  # noqa: E402


def prepare(root: Path, runner=None):
    commands = [
        ("native", ["swift", "build", "--build-path", "build/swiftpm", "--build-tests"]),
        ("audit-helpers", [sys.executable, str(Path(__file__).resolve()), "--helpers-only"]),
    ]
    return execute(
        commands,
        root / "build/ci-verification/compile",
        runner=subprocess.run if runner is None else runner,
        workers=2,
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helpers-only", action="store_true")
    args = parser.parse_args(argv)
    if args.helpers_only:
        # Keep the authoritative compiler recipe and source/mtime checks in the existing helper.
        from tools.native_ui import native_binary

        native_binary("desktop_audit")
        native_binary("desktop_focus_host")
        return 0
    rows = prepare(ROOT)
    succeeded = {row["name"]: row["returncode"] == 0 for row in rows}
    if output := os.environ.get("GITHUB_OUTPUT"):
        with Path(output).open("a") as stream:
            stream.write("native_build_succeeded=" + str(succeeded["native"]).lower() + "\n")
            stream.write("audit_helpers_succeeded=" + str(succeeded["audit-helpers"]).lower() + "\n")
    print(json.dumps({"compile_succeeded": succeeded, "ran_products": False}))
    return 0 if all(succeeded.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
