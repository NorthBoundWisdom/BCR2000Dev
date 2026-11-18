#!/usr/bin/env python3
"""Verify the portable manifest slice without changing source, dependencies or native behavior."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
NATIVE = {
    "BCRAgentConsole",
    "BCRProviderService",
    "BCRCoreMIDIDriver",
    "BCRHTTPTransport",
    "BCRAgentConsoleTests",
    "BCRNativeTransportTests",
}
REQUIRED = {
    "BCRFoundation",
    "BCRSurfaceDomain",
    "BCRPluginRuntime",
    "BCRPluginHost",
    "BCRExamples",
    "BCRConfigurationAdapter",
    "BCRPersistenceAdapter",
    "BCRMCPAdapter",
    "BCRProviderApplication",
    "BCRProviderMCPAdapter",
    "BCRCodexAdapter",
    "BCRProfileTool",
    "BCRTestSupport",
    "BCRTimingTestSupport",
    "BCRAgentCoreTests",
    "BCRCodexAdapterTests",
    "BCRSurfaceDomainTests",
    "BCRPluginHostTests",
    "BCRProviderDomainTests",
    "BCRProviderAdapterTests",
}


def inspect(package):
    targets = {target["name"]: target for target in package["targets"]}
    errors = []
    if set(targets) != REQUIRED:
        errors.append(
            f"Portable targets differ: missing={sorted(REQUIRED - set(targets))}, extra={sorted(set(targets) - REQUIRED)}"
        )
    for name, target in targets.items():
        for item in target.get("dependencies", []):
            dependency = item.get("byName", item.get("target", item.get("product", [""])))[0]
            if dependency in NATIVE:
                errors.append(f"Native dependency in portable slice: {name} -> {dependency}")
    if "RecordingMIDIService.swift" not in targets.get("BCRTestSupport", {}).get("exclude", []):
        errors.append("Native test helper must be excluded from portable slice")
    return errors


def main():
    environment = dict(os.environ, BCR_PORTABLE_BUILD="1")
    result = subprocess.run(
        ["swift", "package", "dump-package"], cwd=ROOT, env=environment, capture_output=True, text=True
    )
    if result.returncode:
        raise SystemExit(result.stderr)
    errors = inspect(json.loads(result.stdout))
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Verified {len(REQUIRED)} portable targets, no native-host dependencies, and native helper exclusion")


if __name__ == "__main__":
    main()
