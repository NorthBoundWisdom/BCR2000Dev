#!/usr/bin/env python3
"""Prepare a versioned, local provider handoff without publishing or copying user state."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from configs.build_environment import load_build_environment  # noqa: E402
from configs.surface_plugins_dependency import ensure_dependency  # noqa: E402


def run(*args):
    return subprocess.check_output(list(map(str, args)), cwd=ROOT, text=True).strip()


def package(output, configuration="release", skip_build=False):
    ensure_dependency(ROOT, environ=load_build_environment(ROOT))
    if output.exists():
        raise ValueError("Use a fresh provider output directory")
    if not skip_build:
        subprocess.run(
            [
                "swift",
                "build",
                "--build-path",
                "build/swiftpm",
                "--configuration",
                configuration,
                "--product",
                "BCRProviderService",
            ],
            cwd=ROOT,
            check=True,
        )
        subprocess.run(
            [
                "swift",
                "build",
                "--build-path",
                "build/swiftpm",
                "--configuration",
                configuration,
                "--product",
                "BCRProfileTool",
            ],
            cwd=ROOT,
            check=True,
        )
    binary_directory = Path(
        run("swift", "build", "--build-path", "build/swiftpm", "--configuration", configuration, "--show-bin-path")
    )
    binary = binary_directory / "BCRProviderService"
    bundle = binary_directory / "BCRAgentConsole_BCRFoundation.bundle"
    profile_tool = binary_directory / "BCRProfileTool"
    if not binary.is_file() or not bundle.is_dir() or not profile_tool.is_file():
        raise ValueError("Provider executable or resource bundle missing")
    output.mkdir(parents=True)
    shutil.copy2(binary, output / "BCRProviderService")
    shutil.copy2(profile_tool, output / "BCRProfileTool")
    shutil.copytree(bundle, output / bundle.name)
    sdk = output / "bcr-provider-sdk-1.0.0.zip"
    with zipfile.ZipFile(sdk, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((ROOT / "Clients/Python/bcr_provider").glob("*.py")):
            info = zipfile.ZipInfo("bcr_provider/" + path.name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())
    surface_sdk = output / "surface-control-sdk-1.0.0.zip"
    with zipfile.ZipFile(surface_sdk, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((ROOT / "Clients/Python/surface_control").glob("*.py")):
            info = zipfile.ZipInfo("surface_control/" + path.name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())
    shutil.copytree(ROOT / "Schemas/SurfaceControl/1.0", output / "surface-control")
    shutil.copy2(ROOT / "docs/SURFACE_SIMULATION.md", output / "SURFACE_SIMULATION.md")
    shutil.copytree(
        ROOT / "Clients/Python/examples", output / "examples", ignore=shutil.ignore_patterns("__pycache__", "*.pyc")
    )
    shutil.copy2(ROOT / "Clients/Python/README.md", output / "SDK_README.md")
    shutil.copytree(
        ROOT / "Support/NativeDiagnostics",
        output / "diagnostics",
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
    )
    shutil.copytree(ROOT / "Schemas/Provider/1.0", output / "schemas")
    shutil.copy2(ROOT / "docs/PROVIDER_API.md", output / "PROVIDER_API.md")
    (output / "adr").mkdir()
    shutil.copy2(
        ROOT / "docs/adr/0001-provider-domain-boundaries.md", output / "adr/0001-provider-domain-boundaries.md"
    )
    shutil.copy2(ROOT / "docs/PROVIDER_QUICKSTART.md", output / "README.md")
    if (ROOT / "LICENSE").is_file():
        shutil.copy2(ROOT / "LICENSE", output / "LICENSE")
    files = {}
    for path in sorted(output.rglob("*")):
        if path.is_file():
            files[str(path.relative_to(output))] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = {
        "artifact": "BCRProviderService",
        "contract_version": "1.0",
        "sdk_version": "1.0.0",
        "source_commit": run("git", "rev-parse", "HEAD"),
        "surface_control_contract": "1.0",
        "surface_control_sdk": "1.0.0",
        "surface_plugins_revision": json.loads((ROOT / "configs/surface_plugins.lock.json").read_text())["revision"],
        "dirty": bool(run("git", "status", "--porcelain")),
        "configuration": configuration,
        "host_architecture": run("uname", "-m"),
        "files_sha256": files,
        "scope": "local handoff, no public release or hardware qualification",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    manifest = package(args.output.resolve(), args.configuration, args.skip_build)
    print(
        json.dumps(
            {
                "artifact": manifest["artifact"],
                "contract_version": manifest["contract_version"],
                "files": len(manifest["files_sha256"]),
                "dirty": manifest["dirty"],
            }
        )
    )


if __name__ == "__main__":
    main()
