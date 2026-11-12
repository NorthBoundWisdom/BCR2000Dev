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
from configs.surface_delivery_index import publish  # noqa: E402


def run(*args):
    return subprocess.check_output(list(map(str, args)), cwd=ROOT, text=True).strip()


# Surface control 1.3 deliverables have exactly one source: the locked shared package.
SURFACE_CONTRACT = "1.3"
SURFACE_SDK = "1.3.0"
# Same root-level names as the other host's delivery, so one consumer loader fits both.
SURFACE_FILES = {
    "control-tools.json": "docs/surface-control-tools.json",
    "surface-control-scenario.schema.json": "docs/surface-control-scenario.schema.json",
    "surface-control-software-v1.json": "fixtures/surface-control-software-v1.json",
    "surface-control-software-v1.1.json": "fixtures/surface-control-software-v1.1.json",
    "surface-control-software-v1.2.json": "fixtures/surface-control-software-v1.2.json",
    "surface-control-software-v1.3.json": "fixtures/surface-control-software-v1.3.json",
    "surface-control.md": "docs/surface-control.md",
    "surface-control-scenarios.md": "docs/surface-control-scenarios.md",
    "surface-control-delivery.md": "docs/surface-control-delivery.md",
    "surface-control-conformance.md": "docs/surface-control-conformance.md",
    "surface-control-conformance-report.schema.json": "docs/surface-control-conformance-report.schema.json",
    "versioning.md": "docs/versioning.md",
    "CHANGELOG.md": "CHANGELOG.md",
    "release-checklist.md": "docs/release-checklist.md",
}
SURFACE_ARTIFACT = "surface-control-simulator"
SURFACE_MANIFEST = "surface-control-manifest.json"


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
    sdk_sources = sorted(
        path
        for name in ("surface_control", "surface_conformance")
        for path in (shared / "clients/python" / name).rglob("*.py")
    )
    if not any(path.parent.name == "surface_conformance" for path in sdk_sources):
        raise ValueError("Locked shared package has no conformance checker")
    with zipfile.ZipFile(surface_sdk, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sdk_sources:
            info = zipfile.ZipInfo(str(path.relative_to(shared / "clients/python")), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())
    shutil.copy2(ROOT / "configs/surface_conformance_roles.json", output / "conformance-roles.json")
    for published, source in SURFACE_FILES.items():
        shutil.copy2(shared / source, output / published)
    # Static description of the --simulation-profile configuration, printed by the delivered binary.
    contract = subprocess.run(
        [str(output / "BCRProviderService"), "--describe-surface"], check=True, capture_output=True, cwd=output
    ).stdout
    (output / "control-contract.json").write_bytes(contract)
    discovery = json.loads(contract)["discovery"]
    shutil.copy2(ROOT / "docs/SURFACE_SIMULATION.md", output / "SURFACE_SIMULATION.md")
    shutil.copy2(ROOT / "docs/SURFACE_CHAIN_STARTUP.md", output / "SURFACE_CHAIN_STARTUP.md")
    shutil.copytree(
        ROOT / "Clients/Python/examples", output / "examples", ignore=shutil.ignore_patterns("__pycache__", "*.pyc")
    )
    # The configurable example is a separate mapping; the top-level manifest remains the default profile.
    example = output / "examples/simulation"
    shutil.copytree(ROOT / "examples/simulation", example)
    example_contract = subprocess.run(
        [
            str(output / "BCRProviderService"),
            "--simulation-configuration",
            str(example / "chassis-controls.json"),
            "--describe-surface",
        ],
        check=True,
        capture_output=True,
        cwd=output,
    ).stdout
    (example / "control-contract.json").write_bytes(example_contract)
    example_discovery = json.loads(example_contract)["discovery"]
    role_profile = json.loads((example / "integrations/pipe/chassis-roles.json").read_text())["profiles"][0]
    if any(
        role_profile[field] != example_discovery["expected"][field]
        for field in ("profile_id", "profile_version", "mapping_revision")
    ):
        raise ValueError("Simulation example role mapping pin differs from the delivered binary")
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
        "simulation_examples": {
            "held_enable_axes": {
                "kind": "generic",
                "configuration": "examples/simulation/chassis-controls.json",
                "contract": "examples/simulation/control-contract.json",
                "readme": "examples/simulation/README.md",
                "mapping_revision": example_discovery["expected"]["mapping_revision"],
            },
            "pipe_chassis_roles": {
                "kind": "integration",
                "consumer": "pipe",
                "public_contract": False,
                "roles": "examples/simulation/integrations/pipe/chassis-roles.json",
                "readme": "examples/simulation/integrations/pipe/README.md",
                "configuration": "examples/simulation/chassis-controls.json",
                "mapping_revision": example_discovery["expected"]["mapping_revision"],
            },
        },
        "surface_plugins_revision": json.loads((ROOT / "configs/surface_plugins.lock.json").read_text())["revision"],
        "surface_plugins_files_sha256": {
            source: hashlib.sha256((shared / source).read_bytes()).hexdigest()
            for source in sorted([*SURFACE_FILES.values(), *(str(path.relative_to(shared)) for path in sdk_sources)])
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
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument("--output", type=Path, help="Fresh directory (original behavior)")
    destination.add_argument("--output-root", type=Path, help="Shared delivery root with atomic INDEX.json")
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if args.output_root:
        manifest, output, _ = publish(
            args.output_root, lambda stage: package(stage, args.configuration, args.skip_build)
        )
    else:
        output = args.output.resolve()
        manifest = package(output, args.configuration, args.skip_build)
    print(
        json.dumps(
            {
                "artifact": manifest["artifact"],
                "contract_version": manifest["contract_version"],
                "files": len(manifest["files_sha256"]),
                "dirty": manifest["dirty"],
                **({"output": str(output)} if args.output_root else {}),
            }
        )
    )


if __name__ == "__main__":
    main()
