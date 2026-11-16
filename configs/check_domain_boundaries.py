#!/usr/bin/env python3
"""Enforce build/import direction and prevent concrete downstream business in provider sources."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys

MACOS_ONLY = {"BCRAgentConsole", "BCRProviderService", "BCRCoreMIDIDriver", "BCRHTTPTransport"}
PORTABLE_BUILD = sys.platform != "darwin" or os.environ.get("BCR_PORTABLE_BUILD") == "1"

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from configs.build_environment import load_build_environment  # noqa: E402
from configs.surface_plugins_dependency import ensure_dependency  # noqa: E402

ALLOWED = {
    "BCRCodexAdapter": {"BCRFoundation"},
    "BCRConfigurationAdapter": {
        "AgentPlugin",
        "BCRExamples",
        "BCRFoundation",
        "BCRSurfaceDomain",
        "ParameterOutputPlugin",
        "SurfacePluginContracts",
    },
    "BCRCoreMIDIDriver": {"BCRFoundation", "BCRSurfaceDomain"},
    "BCRExamples": {"BCRFoundation", "BCRSurfaceDomain", "ExampleParameterSets"},
    "BCRFoundation": {"SimulationContracts", "SurfacePluginContracts"},
    "BCRHTTPTransport": {"BCRMCPAdapter", "BCRFoundation", "BCRSurfaceDomain"},
    "BCRMCPAdapter": {
        "BCRFoundation",
        "BCRPluginRuntime",
        "BCRSurfaceDomain",
        "RemoteToolContracts",
        "SurfacePluginContracts",
    },
    "BCRPersistenceAdapter": {
        "AgentPlugin",
        "BCRConfigurationAdapter",
        "BCRExamples",
        "BCRFoundation",
        "BCRSurfaceDomain",
    },
    "BCRPluginHost": {
        "AgentPlugin",
        "AgentRemoteBinding",
        "BCRConfigurationAdapter",
        "BCRFoundation",
        "BCRPluginRuntime",
        "BCRSurfaceDomain",
        "SurfacePluginContracts",
    },
    "BCRPluginRuntime": {"SurfacePluginContracts", "RemoteToolContracts"},
    "BCRProfileTool": {"BCRConfigurationAdapter"},
    "BCRProviderApplication": {
        "BCRFoundation",
        "BCRPluginRuntime",
        "BCRSurfaceDomain",
        "ChassisPlugin",
        "ChassisRemoteBinding",
        "RemoteToolContracts",
        "RobotPlugin",
        "RobotRemoteBinding",
        "SurfacePluginContracts",
    },
    "BCRProviderMCPAdapter": {
        "BCRFoundation",
        "BCRMCPAdapter",
        "BCRProviderApplication",
        "BCRSurfaceDomain",
        "ChassisPlugin",
        "RobotPlugin",
        "SurfaceControlContracts",
        "SurfacePluginContracts",
    },
    "BCRProviderService": {
        "BCRConfigurationAdapter",
        "BCRCoreMIDIDriver",
        "BCRFoundation",
        "BCRHTTPTransport",
        "BCRMCPAdapter",
        "BCRPersistenceAdapter",
        "BCRProviderApplication",
        "BCRProviderMCPAdapter",
        "BCRSurfaceDomain",
    },
    "BCRSurfaceDomain": {"BCRFoundation", "SurfacePluginContracts"},
}
PURE = {"BCRProviderApplication", "BCRFoundation", "BCRSurfaceDomain", "BCRPluginRuntime"}


# These are architectural roles, independent of the exact per-module allowlists above.
# MIDI currently combines device decoding and the native transport in one target; that
# outer target may consume the runtime but cannot be imported by the runtime or bridges.
LAYERS = {
    "BCRFoundation": "values",
    **{name: "runtime" for name in PURE - {"BCRFoundation"}},
    "BCRExamples": "runtime",
    "BCRPluginHost": "bridge",
    "BCRConfigurationAdapter": "bridge",
    "BCRPersistenceAdapter": "bridge",
    "BCRMCPAdapter": "bridge",
    "BCRProviderMCPAdapter": "bridge",
    "BCRCoreMIDIDriver": "device_transport",
    "BCRHTTPTransport": "transport",
    "BCRCodexAdapter": "transport",
    "BCRAgentConsole": "composition",
    "BCRProviderService": "composition",
    "BCRProfileTool": "composition",
}
LAYER_DEPENDENCIES = {
    "values": {"values"},
    "runtime": {"values", "runtime"},
    "bridge": {"values", "runtime", "bridge"},
    "device_transport": {"values", "runtime"},
    "transport": {"values", "runtime", "bridge"},
    "composition": {"values", "runtime", "bridge", "device_transport", "transport", "composition"},
}
IMPORTS = re.compile(
    r"^[ \t]*(?:(?:@\w+(?:\([^()\n]*\))?|public|package|internal|fileprivate|private)\s+)*"
    r"import\s+(?:(?:struct|enum|class|protocol|func|var|typealias)\s+)?(\w+)",
    re.MULTILINE,
)
PLATFORM_IMPORTS = {"AppKit", "SwiftUI", "CoreMIDI", "Network", "Combine", "Security"}


def target_dependencies(target):
    return {
        entry.get("byName", entry.get("target", entry.get("product", [""])))[0]
        for entry in target.get("dependencies", [])
    }


def check_layers(targets, root=ROOT):
    """Pure checker entry point: tests can supply a temporary source tree and manifest."""
    errors = []
    production = {
        name: target for name, target in targets.items() if target.get("type") != "test" and name != "BCRTestSupport"
    }
    for name, target in production.items():
        if name not in LAYERS:
            errors.append("Unclassified production module: " + name)
            continue
        layer = LAYERS[name]
        for dependency in target_dependencies(target):
            if dependency in production and LAYERS.get(dependency) not in LAYER_DEPENDENCIES[layer]:
                errors.append(f"Layer violation: {name} ({layer}) -> {dependency} ({LAYERS.get(dependency)})")
        for path in (root / "Sources" / name).rglob("*.swift"):
            for imported in IMPORTS.findall(path.read_text()):
                if layer in {"runtime", "values"} and imported in PLATFORM_IMPORTS:
                    errors.append(f"Layer platform import violation: {path.relative_to(root)} -> {imported}")
                if imported in production and LAYERS.get(imported) not in LAYER_DEPENDENCIES[layer]:
                    errors.append(f"Layer import violation: {path.relative_to(root)} -> {imported}")
    return errors


def check():
    ensure_dependency(ROOT, environ=load_build_environment(ROOT))
    package = json.loads(
        subprocess.check_output(
            [
                "swift",
                "package",
                "--scratch-path",
                str(ROOT / "build" / ("swiftpm-linux" if sys.platform == "linux" else "swiftpm")),
                "dump-package",
            ],
            cwd=ROOT,
            text=True,
        )
    )
    targets = {target["name"]: target for target in package["targets"]}
    errors = check_layers(targets)
    for name, allowed in ALLOWED.items():
        if name not in targets:
            if PORTABLE_BUILD and name in MACOS_ONLY:
                continue
            errors.append("Missing module: " + name)
            continue
        dependencies = {
            entry.get("byName", entry.get("target", entry.get("product", [""])))[0]
            for entry in targets[name]["dependencies"]
        }
        if not dependencies <= allowed:
            errors.append(f"{name} has forbidden dependencies: {sorted(dependencies - allowed)}")
        for path in (ROOT / "Sources" / name).rglob("*.swift"):
            text = path.read_text()
            imports = set(IMPORTS.findall(text))
            internal = {
                value
                for value in imports
                if value.startswith("BCR")
                or value
                in {
                    "RemoteToolContracts",
                    "AgentRemoteBinding",
                    "RobotRemoteBinding",
                    "ChassisRemoteBinding",
                    "OutputRemoteBinding",
                    "SurfacePluginContracts",
                    "AgentPlugin",
                    "SimulationContracts",
                    "RobotPlugin",
                    "ChassisPlugin",
                    "ParameterOutputPlugin",
                    "ExampleParameterSets",
                }
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
        # Workspace D8 preserves only legacy enum/callback shapes. Actual interpretation,
        # namespaces and slot-keyed feedback belong to the configuration adapter.
        if re.search(r'\bagentFeedback\b|\bsetAgentFeedback\b|"agent\.', text):
            errors.append(f"Legacy plugin interpretation leaked into {path.relative_to(ROOT)}")
    canonical = ROOT / "Schemas/Provider/1.0/provider.schema.json"
    resource = ROOT / "Sources/BCRFoundation/Resources/provider.schema.json"
    if canonical.read_bytes() != resource.read_bytes():
        errors.append("Published and bundled contract schemas differ")
    return errors


if __name__ == "__main__":
    errors = check()
    if errors:
        raise SystemExit("\n".join(errors))
    print(
        f"Verified {len(ALLOWED)} module allowlists and {len(LAYERS)} classified layer boundaries, pure domains and business-neutral provider sources"
    )
