"""Connect native tests to the Tests-only J3 oracle; contains no legacy algorithm."""

from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import sys

TRACE_ENV = "BCR_J3_SHADOW_ROOT"


@contextmanager
def capture(root: Path, directory: Path):
    manifest = (root / "Package.swift").read_text()
    if not re.search(r'\.product\(\s*name:\s*"SurfaceBindingContext"\s*,\s*package:\s*"ControlSurfaceKit"', manifest):
        yield None  # Generic native-runner fixtures do not contain this product/runtime.
        return
    trace_source = root / "Sources/BCRSurfaceDomain/SurfaceKernelTrace.swift"
    oracle = root / "Tests/J3Support/verify_runtime_shadow.py"
    if not trace_source.is_file() or not oracle.is_file():
        raise RuntimeError("Kernel native verification requires both the real input/result tap and Tests-only oracle")
    previous = os.environ.get(TRACE_ENV)
    trace = Path(previous).resolve() if previous else directory / "kernel-runtime"
    trace.mkdir(parents=True, exist_ok=True)
    if any(trace.iterdir()):
        raise RuntimeError("Kernel native verification refuses reused operation evidence: " + str(trace))
    metadata = {
        "trace_directory": str(trace),
        "oracle": str(oracle),
        "oracle_revision": "36692f1422b0c3952f9048847a0bafd65421bc72",
    }
    (directory / "kernel-verification.json").write_text(json.dumps(metadata, indent=2) + "\n")
    os.environ[TRACE_ENV] = str(trace)
    try:
        yield trace
    finally:
        if previous is None:
            os.environ.pop(TRACE_ENV, None)
        else:
            os.environ[TRACE_ENV] = previous


def verify(root: Path, directory: Path, trace: Path | None, remaining: float):
    if trace is None:
        return
    if remaining <= 0:
        raise RuntimeError("Kernel legacy verification exceeded the original native suite deadline")
    command = [
        sys.executable,
        str(root / "Tests/J3Support/verify_runtime_shadow.py"),
        str(trace),
        "--output",
        str(directory / "kernel-legacy-proof.json"),
    ]
    with (directory / "kernel-legacy.log").open("w") as log:
        result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=remaining)
    if result.returncode:
        raise RuntimeError(
            "Actual Kit results differ from the Tests-only 366 oracle; see " + str(directory / "kernel-legacy.log")
        )
    proof = json.loads((directory / "kernel-legacy-proof.json").read_text())
    required = {
        "binding.lookup",
        "connection.transition",
        "scope.transport.accepted",
        "index.upsert",
        "index.removeFirst",
    }
    absent = required - {operation for operation, count in proof["operation_counts"].items() if count > 0}
    if absent:
        raise RuntimeError("Kernel legacy verification missed real core operations: " + ", ".join(sorted(absent)))
    print(
        "Verified actual Kit core operations with the Tests-only 366 legacy oracle: "
        + str(directory / "kernel-legacy-proof.json"),
        flush=True,
    )
