#!/usr/bin/env python3
"""Measure the existing Debug Provider tick with an injected clock; opens no hardware or ports."""

from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHARED_MODULES = [
    "SurfacePluginContracts",
    "RemoteToolContracts",
    "SimulationContracts",
    "AgentPlugin",
    "AgentRemoteBinding",
    "ParameterOutputPlugin",
    "OutputRemoteBinding",
    "RobotPlugin",
    "RobotRemoteBinding",
    "ChassisPlugin",
    "ChassisRemoteBinding",
    "ExampleParameterSets",
    "SurfaceControlContracts",
]
SOURCE = r"""import Foundation
import BCRProviderApplication
import BCRPluginRuntime
import SurfacePluginContracts
import RobotRemoteBinding
import ChassisRemoteBinding

@main enum Probe {
    @MainActor static func main() throws {
        final class Clock { var value = 0.0 }
        let n = __ITERATIONS__
        let initialized = ProcessInfo.processInfo.arguments.contains("--initialized")
        var samples: [[String: Double]] = []
        for _ in 0 ..< __SAMPLES__ {
            let clock = Clock()
            let app = ProviderApplication(configuration: .init(robot: true, chassis: true), monotonic: { clock.value })
            if initialized {
                let access = ProviderAccess(write: true, robot: true, chassis: true, simulation: true)
                _ = try app.executeRobot(.initialize(app.robotState().metadata.generation, Array(repeating: 0, count: 6)), access: access)
                _ = try app.executeChassis(.initialize(app.chassisState().metadata.generation, [0, 0, 0]), access: access)
            }
            var row: [String: Double] = [:]
            var checksum = 0
            func measure(_ name: String, _ work: () throws -> Void) rethrows {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0 ..< n { try work() }
                row[name] = (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(n)
            }
            measure("tick_ms") { clock.value += 0.02; app.tick() }
            measure("state_ms") { checksum += app.state().objectValue?.count ?? 0 }
            try measure("snapshots_ms") { _ = try app.robotState(); _ = try app.chassisState() }
            try measure("snapshot_encoding_ms") { _ = try JSONValue.encoded(app.robotState()); _ = try JSONValue.encoded(app.chassisState()) }
            row["checksum"] = Double(checksum)
            samples.append(row)
        }
        let out: [String: Any] = ["iterations_per_sample": n, "samples": samples, "initialized": initialized, "configuration": "debug robot+chassis; injected clock 20ms, no ports/devices"]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
"""


def checked(command, log):
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    log.write_text(result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=500)
    parser.add_argument("--samples", type=int, default=5)
    args = parser.parse_args()
    if sys.platform != "darwin" or not (1 <= args.iterations <= 100000 and 1 <= args.samples <= 100):
        parser.error("requires macOS and positive bounded iterations/samples")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    checked(["swift", "build", "--build-path", "build/swiftpm"], output / "build.log")
    binary = Path(
        checked(["swift", "build", "--build-path", "build/swiftpm", "--show-bin-path"], output / "binary-path.log")
    )
    package = json.loads(checked(["swift", "package", "dump-package"], output / "package.log"))
    modules = [
        target["name"]
        for target in package["targets"]
        if target["type"] == "regular" and target["name"] != "BCRTestSupport"
    ] + SHARED_MODULES
    combined = [binary / (name + ".o") for name in modules]
    if all(path.is_file() for path in combined):
        objects, import_path = combined, binary  # XCBuild layout
    else:
        objects = [path for name in modules for path in (binary / (name + ".build")).glob("*.o")]
        import_path = binary / "Modules"  # native SwiftPM layout
    if not objects:
        raise RuntimeError("No compiled library objects found")
    source = output / "probe.swift"
    source.write_text(SOURCE.replace("__ITERATIONS__", str(args.iterations)).replace("__SAMPLES__", str(args.samples)))
    executable = output / "probe"
    target = platform.machine() + "-apple-macosx14.0"
    checked(
        [
            "swiftc",
            "-parse-as-library",
            "-Onone",
            "-target",
            target,
            "-I",
            str(import_path),
            str(source),
            *map(str, objects),
            "-framework",
            "AppKit",
            "-framework",
            "CoreMIDI",
            "-framework",
            "Network",
            "-framework",
            "Security",
            "-o",
            str(executable),
        ],
        output / "compile.log",
    )
    result = {
        "source_revision": checked(["git", "rev-parse", "HEAD"], output / "revision.log"),
        "method": "Debug current library objects; injected 20ms clock; five 500-iteration samples by default; no wall-clock sleeps/devices",
        "provider_source_sha256": hashlib.sha256(
            (ROOT / "Sources/BCRProviderApplication/ProviderApplication.swift").read_bytes()
        ).hexdigest(),
    }
    for name, options in [("uninitialized", []), ("initialized", ["--initialized"])]:
        measured = json.loads(checked([str(executable), *options], output / (name + ".json")))
        measured["median_ms"] = {
            key: statistics.median(row[key] for row in measured["samples"])
            for key in ("tick_ms", "state_ms", "snapshots_ms", "snapshot_encoding_ms")
        }
        result[name] = measured
    (output / "report.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
