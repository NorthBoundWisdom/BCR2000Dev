#!/usr/bin/env python3
"""Enforce build/import direction and prevent concrete downstream business in provider sources."""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = {
    "BCRProfileTool": {"BCRConfigurationAdapter"},
    "BCRFoundation": set(),
    "BCRAgentDomain": {"BCRFoundation"},
    "BCRPluginHost": {"BCRFoundation", "BCRAgentDomain", "BCRSurfaceDomain", "SurfacePluginContracts", "AgentPlugin"},
    "BCRCodexAdapter": {"BCRFoundation", "BCRAgentDomain"},
    "BCRSurfaceDomain": {"BCRFoundation"},
    "BCROutputDomain": {"BCRFoundation"},
    "BCRSimulationKernel": {"BCRFoundation"},
    "BCRRobotDomain": {"BCRFoundation", "BCRSimulationKernel"},
    "BCRChassisDomain": {"BCRFoundation", "BCRSimulationKernel"},
    "BCRProviderApplication": {"BCRFoundation", "BCRSurfaceDomain", "BCRRobotDomain", "BCRChassisDomain"},
    "BCRExamples": {"BCRFoundation", "BCRSurfaceDomain"},
    "BCRConfigurationAdapter": {"BCRFoundation", "BCRSurfaceDomain", "BCRExamples"},
    "BCRPersistenceAdapter": {"BCRFoundation", "BCRSurfaceDomain", "BCRExamples", "BCRConfigurationAdapter"},
    "BCRMCPAdapter": {"BCRFoundation", "BCRSurfaceDomain"},
    "BCRProviderMCPAdapter": {
        "BCRFoundation",
        "BCRSurfaceDomain",
        "BCRRobotDomain",
        "BCRChassisDomain",
        "BCRProviderApplication",
        "BCRMCPAdapter",
    },
    "BCRHTTPTransport": {"BCRFoundation", "BCRSurfaceDomain", "BCRMCPAdapter"},
    "BCRCoreMIDIDriver": {"BCRFoundation", "BCRSurfaceDomain"},
    "BCRProviderService": {
        "BCRFoundation",
        "BCRSurfaceDomain",
        "BCRConfigurationAdapter",
        "BCRPersistenceAdapter",
        "BCRMCPAdapter",
        "BCRHTTPTransport",
        "BCRCoreMIDIDriver",
        "BCRProviderApplication",
        "BCRProviderMCPAdapter",
    },
}
PURE = {
    "BCRFoundation",
    "BCRAgentDomain",
    "BCRSurfaceDomain",
    "BCROutputDomain",
    "BCRSimulationKernel",
    "BCRRobotDomain",
    "BCRChassisDomain",
    "BCRProviderApplication",
}


def check():
    package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT, text=True))
    targets = {target["name"]: target for target in package["targets"]}
    errors = []
    for name, allowed in ALLOWED.items():
        if name not in targets:
            errors.append("Missing module: " + name)
            continue
        dependencies = {
            entry.get("byName", entry.get("target", entry.get("product", [""])))[0]
            for entry in targets[name]["dependencies"]
        }
        if not dependencies <= allowed:
            errors.append(f"{name} has forbidden dependencies: {sorted(dependencies - allowed)}")
        for path in (ROOT / "Sources" / name).glob("*.swift"):
            text = path.read_text()
            imports = set(re.findall(r"^import (\w+)", text, re.MULTILINE))
            internal = {
                value
                for value in imports
                if value.startswith("BCR") or value in {"SurfacePluginContracts", "AgentPlugin"}
            }
            if not internal <= allowed:
                errors.append(f"{path.relative_to(ROOT)} imports a forbidden module")
            if name in PURE and imports & {"AppKit", "SwiftUI", "CoreMIDI", "Network", "Combine", "Security"}:
                errors.append(f"{name} depends on platform/UI/transport infrastructure")
            if any(word in text.lower() for word in ("flashroll", "robimpipe", "pipe_welding")):
                errors.append(f"Concrete downstream business in {path.relative_to(ROOT)}")
    for path in (ROOT / "Sources/BCRSurfaceDomain").glob("*.swift"):
        text = path.read_text()
        if '"arm.enabled"' in text or "CodexSession" in text or "AgentStateMachine" in text:
            errors.append(f"Example/backend policy leaked into {path.relative_to(ROOT)}")
    canonical = ROOT / "Schemas/Provider/1.0/provider.schema.json"
    resource = ROOT / "Sources/BCRFoundation/Resources/provider.schema.json"
    if canonical.read_bytes() != resource.read_bytes():
        errors.append("Published and bundled contract schemas differ")
    return errors


if __name__ == "__main__":
    errors = check()
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Verified {len(ALLOWED)} module boundaries, pure domains and business-neutral provider sources")
