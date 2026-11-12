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


# Surface control 1.2 deliverables have exactly one source: the locked shared package.
SURFACE_CONTRACT = "1.2"
SURFACE_SDK = "1.2.0"
# Same root-level names as the other host's delivery, so one consumer loader fits both.
SURFACE_FILES = {
    "control-tools.json": "docs/surface-control-tools.json",
    "surface-control-scenario.schema.json": "docs/surface-control-scenario.schema.json",
    "surface-control-software-v1.json": "fixtures/surface-control-software-v1.json",
    "surface-control-software-v1.1.json": "fixtures/surface-control-software-v1.1.json",
    "surface-control-software-v1.2.json": "fixtures/surface-control-software-v1.2.json",
    "surface-control.md": "docs/surface-control.md",
    "surface-control-scenarios.md": "docs/surface-control-scenarios.md",
}
SURFACE_ARTIFACT = "surface-control-simulator"
SURFACE_MANIFEST = "surface-control-manifest.json"
SURFACE_SDK_SOURCE = "clients/python/surface_control/__init__.py"


def package(output, configuration="release", skip_build=False):
    shared = Path(ensure_dependency(ROOT, environ=load_build_environment(ROOT)))
    if not shared.is_absolute():
        shared = ROOT / shared
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
    surface_sdk = output / f"surface-control-sdk-{SURFACE_SDK}.zip"
    with zipfile.ZipFile(surface_sdk, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        info = zipfile.ZipInfo("surface_control/__init__.py", date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, (shared / SURFACE_SDK_SOURCE).read_bytes())
    for published, source in SURFACE_FILES.items():
        shutil.copy2(shared / source, output / published)
    # Static description of the --simulation-profile configuration, printed by the delivered binary.
    contract = subprocess.run(
        [str(output / "BCRProviderService"), "--describe-surface"], check=True, capture_output=True, cwd=output
    ).stdout
    (output / "control-contract.json").write_bytes(contract)
    discovery = json.loads(contract)["discovery"]
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

    def hashes():
        return {
            str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(output.rglob("*"))
            if path.is_file()
        }

    source_commit, dirty = run("git", "rev-parse", "HEAD"), bool(run("git", "status", "--porcelain"))
    # Common surface delivery fields (SurfacePlugins docs/surface-control-delivery.md). They describe
    # the optional surface control simulation only, never the provider's hardware source.
    surface = {
        "schema_version": 1,
        "source": "simulation",
        "source_commit": source_commit,
        "source_dirty": dirty,
        "surface_control_contract": SURFACE_CONTRACT,
        "surface_control_sdk": SURFACE_SDK,
        "profile_id": discovery["profile"]["id"],
        "profile_version": discovery["profile"]["version"],
        "mapping_revision": discovery["expected"]["mapping_revision"],
        "surface_plugins_revision": json.loads((ROOT / "configs/surface_plugins.lock.json").read_text())["revision"],
        "surface_plugins_files_sha256": {
            source: hashlib.sha256((shared / source).read_bytes()).hexdigest()
            for source in sorted([*SURFACE_FILES.values(), SURFACE_SDK_SOURCE])
        },
    }
    # `artifact` is the one common field that collides with Provider 1.0 (its consumers require
    # "BCRProviderService"), so a surface-only manifest carries the neutral value. It lists every
    # delivered file except the two manifests; manifest.json below also pins this file.
    (output / SURFACE_MANIFEST).write_text(
        json.dumps({"artifact": SURFACE_ARTIFACT, **surface, "files_sha256": hashes()}, indent=2, sort_keys=True) + "\n"
    )
    files = hashes()
    manifest = {
        "artifact": "BCRProviderService",
        "contract_version": "1.0",
        "sdk_version": "1.0.0",
        **surface,
        "surface_artifact": SURFACE_ARTIFACT,
        "surface_manifest": SURFACE_MANIFEST,
        "surface_plugins_materialized_revision": run("git", "-C", str(shared), "rev-parse", "HEAD"),
        "dirty": dirty,
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
