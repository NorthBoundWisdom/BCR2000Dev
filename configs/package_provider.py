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
from configs.display_targets import generate as generate_display_targets  # noqa: E402
from configs.check_handoff_addresses import render as render_handoff_addresses  # noqa: E402
from configs.surface_plugins_dependency import ensure_dependency  # noqa: E402
from configs.surface_delivery_index import publish  # noqa: E402


def run(*args):
    return subprocess.check_output(list(map(str, args)), cwd=ROOT, text=True).strip()


# Surface control deliverables (simulation contract 1.3, optional hardware 1.4, SDK 1.4.0) have
# exactly one source: the locked shared package.
SURFACE_CONTRACT = "1.3"
SURFACE_SDK = "1.4.0"
# Same root-level names as the other host's delivery, so one consumer loader fits both.
SURFACE_FILES = {
    "control-tools.json": "docs/surface-control-tools.json",
    "hardware-control-tools.json": "docs/surface-control-hardware-tools.json",
    "hardware-control-examples.json": "docs/surface-control-hardware-examples.json",
    "surface-control-diagnostics.md": "docs/surface-control-diagnostics.md",
    "surface-control-diagnostic-capture.schema.json": "docs/surface-control-diagnostic-capture.schema.json",
    "surface-control-hardware-v1.4.json": "fixtures/surface-control-hardware-v1.4.json",
    "surface-control-hardware-independent-v1.4.json": "fixtures/surface-control-hardware-independent-v1.4.json",
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
    "status-panel-demo.md": "docs/status-panel-demo.md",
}
SURFACE_ARTIFACT = "surface-control-simulator"
SURFACE_MANIFEST = "surface-control-manifest.json"


def candidate_status(*, dirty, source_unpushed):
    """Private artifact label, not a served contract/schema or a release authorization."""
    return "local-unpushed-candidate" if dirty or source_unpushed else "remote-head-unreleased-candidate"


def package(output, configuration="release", skip_build=False, hardware_map=None):
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
        for name in ("surface_control", "surface_conformance", "surface_control_diagnostics", "surface_panel_demo")
        for path in (shared / "clients/python" / name).rglob("*")
        if path.is_file() and path.suffix in (".py", ".md", ".json")
    )
    if not any(path.parent.name == "surface_conformance" for path in sdk_sources):
        raise ValueError("Locked shared package has no conformance checker")
    with zipfile.ZipFile(surface_sdk, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sdk_sources:
            info = zipfile.ZipInfo(str(path.relative_to(shared / "clients/python")), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())
    # Test doubles are a separate, unmistakably test-only asset, never a runtime SDK member.
    testing_sdk = output / f"TEST-ONLY-surface-control-testing-{SURFACE_SDK}.zip"
    test_support_sources = sorted(
        path
        for path in (shared / "clients/python/surface_control_testing").rglob("*")
        if path.is_file() and path.suffix in (".py", ".md")
    )
    with zipfile.ZipFile(testing_sdk, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in test_support_sources:
            info = zipfile.ZipInfo(str(path.relative_to(shared / "clients/python")), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())
    with zipfile.ZipFile(surface_sdk) as archive:
        if any(name.startswith("surface_control_testing/") for name in archive.namelist()):
            raise ValueError("Runtime SDK must not contain test doubles")
    shutil.copy2(ROOT / "docs/provider-tool-compatibility.json", output / "provider-tool-compatibility.json")
    shutil.copy2(ROOT / "configs/surface_conformance_roles.json", output / "conformance-roles.json")
    for published, source in SURFACE_FILES.items():
        shutil.copy2(shared / source, output / published)
    # Static description of the --simulation-profile configuration, printed by the delivered binary.
    contract = subprocess.run(
        [str(output / "BCRProviderService"), "--describe-surface"], check=True, capture_output=True, cwd=output
    ).stdout
    (output / "control-contract.json").write_bytes(contract)
    discovery = json.loads(contract)["discovery"]
    hardware_discovery = None
    if hardware_map is not None:
        shutil.copy2(hardware_map, output / "hardware-map.json")
        hardware_contract = subprocess.run(
            [
                str(output / "BCRProviderService"),
                "--source",
                "hardware",
                "--hardware-profile",
                "--hardware-map",
                str(output / "hardware-map.json"),
                "--describe-surface",
            ],
            check=True,
            capture_output=True,
            cwd=output,
        ).stdout
        (output / "hardware-control-contract.json").write_bytes(hardware_contract)
        hardware_discovery = json.loads(hardware_contract)["discovery"]
        shutil.copy2(ROOT / "examples/hardware/role-readiness-request.json", output / "role-readiness-request.json")
        shutil.copy2(ROOT / "docs/HARDWARE_ROLE_READINESS.md", output / "HARDWARE_ROLE_READINESS.md")
        readiness = subprocess.run(
            [
                str(output / "BCRProfileTool"),
                "--check-hardware-roles",
                str(output / "hardware-map.json"),
                str(output / "role-readiness-request.json"),
                "--hardware-output",
                "write",
                "--allow-surface-feedback",
            ],
            capture_output=True,
            cwd=output,
        )
        if readiness.returncode not in (0, 3):
            raise ValueError("Hardware role readiness input validation failed")
        readiness_report = json.loads(readiness.stdout)
        if readiness_report.get("hardware_qualified") is not False or readiness_report.get("ready") != (
            readiness.returncode == 0
        ):
            raise ValueError("Invalid offline role readiness report")
        (output / "hardware-role-readiness.json").write_bytes(readiness.stdout)
        shutil.copy2(ROOT / "docs/HARDWARE_CANDIDATES.md", output / "HARDWARE_CANDIDATES.md")
        candidate = output / "candidates/unverified-four-role"
        staged_candidate = subprocess.run(
            [
                str(output / "BCRProfileTool"),
                "--stage-hardware-candidate",
                str(output / "hardware-map.json"),
                str(output / "role-readiness-request.json"),
                str(candidate),
            ],
            capture_output=True,
            cwd=output,
        )
        if staged_candidate.returncode != 0:
            # Fail closed: the example roles must exist as momentary buttons/absolute axes in this map.
            raise ValueError(
                "Independent candidate staging failed without changing source files: "
                + (staged_candidate.stdout.decode(errors="replace").strip() or "no report")
            )
        checked_candidate = subprocess.run(
            [str(output / "BCRProfileTool"), "--verify-hardware-candidate", str(candidate)],
            capture_output=True,
            cwd=output,
        )
        if checked_candidate.returncode != 0 or json.loads(checked_candidate.stdout).get("ready") is not False:
            raise ValueError("Unverified candidate integrity/status check failed")
        candidate_plan = json.loads(staged_candidate.stdout)
        evidence = {
            "selected_buttons": [
                {
                    "role": row["role"],
                    "control_id": row["control_id"],
                    "learned_midi_identity": row["midi"],
                    "press_release_capture": None,
                    "current_preset_match": None,
                    "physical_led_observation": None,
                }
                for row in candidate_plan["changes"]
                if row["role"] in ("enable", "stop")
            ],
            "artifact": "candidate-attended-evidence-plan",
            "executable_now": False,
            "candidate": "candidates/unverified-four-role/candidate-manifest.json",
            "hardware_qualified": False,
            "automatic_application": False,
            "automatic_device_connection": False,
            "required_fields": [
                "current_preset_capture_sha256",
                "learned_map_sha256",
                "endpoint_identity",
                "epoch",
                "link_state",
                "event_gap_absent",
            ],
            "per_selected_button": {
                "control_id": "from candidate changes",
                "input_midi_identity": "unchanged learned address",
                "observed_press_release": "record actual values, timestamps and source capture hash; do not infer from declarations",
                "display_output_identity_and_encoding": "requires independent evidence; existing route is a proposal",
                "physical_on_off_observation": "record user response after a separately authorized attended display request",
            },
            "instructions": "No physical step has run; do not modify presets, auto-apply, or treat software_ready as qualification",
        }
        (output / "candidate-attended-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        shutil.copy2(
            ROOT / "configs/hardware_surface_conformance_roles.json", output / "hardware-conformance-roles.json"
        )
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
    for name in (
        "PROVIDER_TOOL_COMPATIBILITY.md",
        "SURFACE_CLIENTS.md",
        "F_PIPE_HANDOFF.md",
        "F_CANDIDATE_ATTENDED.md",
        "STATUS_PANEL_BUDGET.md",
        "status-panel-budget-evidence.json",
        "H_STATUS_PANEL_ATTENDED.md",
    ):
        if hardware_map is not None and name in ("F_PIPE_HANDOFF.md", "F_CANDIDATE_ATTENDED.md"):
            (output / name).write_text(render_handoff_addresses((ROOT / "docs" / name).read_text(), hardware_map))
        else:
            shutil.copy2(ROOT / "docs" / name, output / name)
    subprocess.run(
        [sys.executable, str(ROOT / "configs/prepare_f_candidate_attended.py"), "--output", str(output / "attended")],
        check=True,
        cwd=ROOT,
    )
    (output / "display-mock-map.json").write_bytes(
        subprocess.check_output([str(output / "BCRProfileTool"), "--describe-mock-map"], cwd=output)
    )
    generate_display_targets(output)
    shutil.copy2(ROOT / "configs/display_targets.py", output / "diagnostics/display_targets.py")
    shutil.copy2(ROOT / "configs/display_budget_report.py", output / "diagnostics/display_budget_report.py")
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
    source_unpushed = int(run("git", "rev-list", "--count", "origin/main..HEAD")) > 0
    # Common surface delivery fields (SurfacePlugins docs/surface-control-delivery.md). They describe
    # the optional surface control simulation only, never the provider's hardware source.
    surface = {
        "schema_version": 1,
        "source": "simulation",
        "source_commit": source_commit,
        "source_dirty": dirty,
        "source_origin_main": run("git", "rev-parse", "origin/main"),
        "source_ahead": int(run("git", "rev-list", "--count", "origin/main..HEAD")),
        "source_behind": int(run("git", "rev-list", "--count", "HEAD..origin/main")),
        "source_unpushed": source_unpushed,
        "status": candidate_status(dirty=dirty, source_unpushed=source_unpushed),
        "published": False,
        "physical_qualification": False,
        "provider_tool_compatibility": "provider-tool-compatibility.json",
        "test_support_zip": f"TEST-ONLY-surface-control-testing-{SURFACE_SDK}.zip",
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
        # The optional hardware profile ships a copy of the operator's learned map; share accordingly.
        "contains_learned_hardware_map": hardware_discovery is not None,
        "hardware_candidates": (
            [
                {
                    "manifest": "candidates/unverified-four-role/candidate-manifest.json",
                    "ready": False,
                    "software_ready": True,
                    "hardware_qualified": False,
                    "test_only": True,
                    "evidence_plan": "candidate-attended-evidence.json",
                    "documentation": "HARDWARE_CANDIDATES.md",
                }
            ]
            if hardware_discovery is not None
            else []
        ),
        "hardware_role_readiness": (
            {
                "report": "hardware-role-readiness.json",
                "request": "role-readiness-request.json",
                "scope": "offline; declared write and display permission; never hardware qualification",
            }
            if hardware_discovery is not None
            else None
        ),
        "test_artifacts": [
            {
                "artifact": "surface-control-test-only-hardware-double",
                "qualification": "test-only",
                "path": testing_sdk.name,
            }
        ],
        "surface_control_profiles": [
            {
                "contract_version": "1.3",
                "source": "simulation",
                "profile_id": discovery["profile"]["id"],
                "profile_version": discovery["profile"]["version"],
                "mapping_revision": discovery["expected"]["mapping_revision"],
            }
        ]
        + (
            [
                {
                    "contract_version": "1.4",
                    "source": "hardware",
                    "profile_id": hardware_discovery["profile"]["id"],
                    "profile_version": hardware_discovery["profile"]["version"],
                    "mapping_revision": hardware_discovery["expected"]["mapping_revision"],
                    "description": "hardware-control-contract.json",
                    "mapping": "hardware-map.json",
                }
            ]
            if hardware_discovery is not None
            else []
        ),
        "surface_plugins_revision": json.loads((ROOT / "configs/surface_plugins.lock.json").read_text())["revision"],
        "surface_plugins_files_sha256": {
            source: hashlib.sha256((shared / source).read_bytes()).hexdigest()
            for source in sorted(
                [
                    *SURFACE_FILES.values(),
                    *(str(path.relative_to(shared)) for path in [*sdk_sources, *test_support_sources]),
                ]
            )
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
    parser.add_argument(
        "--hardware-map", type=Path, help="Explicit learned map to include the optional hardware 1.4 profile"
    )
    args = parser.parse_args()
    if args.output_root:
        manifest, output, _ = publish(
            args.output_root, lambda stage: package(stage, args.configuration, args.skip_build, args.hardware_map)
        )
    else:
        output = args.output.resolve()
        manifest = package(output, args.configuration, args.skip_build, args.hardware_map)
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
