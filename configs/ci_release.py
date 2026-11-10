#!/usr/bin/env python3
"""Validate release versions and the complete set of packaged CI artifacts."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.macos_workflow import PRODUCT, _sha  # noqa: E402


def release_version(value: str) -> str:
    version = value.removeprefix("v")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Release version must be major.minor.patch, optionally prefixed with v.")
    return version


def validate_assets(
    directory: Path, version: str, commit: str, distribution: str = "ad-hoc", build_number: str = "1"
) -> None:
    version = release_version(version)
    if distribution not in {"ad-hoc", "developer-id"} or not re.fullmatch(r"[1-9][0-9]*", build_number):
        raise ValueError("Invalid release distribution/build number")
    stem = f"{PRODUCT}_v{version}_{build_number}_macOS_universal_{distribution}"
    expected_assets = {f"{stem}.zip", f"{stem}.dmg"}
    actual_assets = {p.name for p in directory.iterdir() if p.suffix in {".zip", ".dmg"}}
    if actual_assets != expected_assets:
        raise ValueError("Release requires exactly the expected universal ZIP and DMG.")
    checksums = []
    for name in sorted(expected_assets):
        asset = directory / name
        proof = json.loads(asset.with_suffix(asset.suffix + ".build.json").read_text())
        expected = {
            "schema_version": 1,
            "asset": name,
            "version": version,
            "build": build_number,
            "commit": commit,
            "dirty": False,
            "architecture": "universal",
            "signature": distribution,
            "notarized": distribution == "developer-id",
            "sha256": _sha(asset),
        }
        if any(type(proof.get(key)) is not type(value) or proof.get(key) != value for key, value in expected.items()):
            raise ValueError(f"Release artifact provenance/hash mismatch: {name}")
        if distribution == "developer-id":
            from configs.driverkit_release import DRIVER_ID, HOST_PRODUCT

            if proof.get("driverkit") != {
                "host": HOST_PRODUCT + ".app",
                "bundle_id": DRIVER_ID,
                "signature": "developer-id",
                "supported_mode": "U-1",
                "notarized": True,
            }:
                raise ValueError("Formal release requires the approved, notarized DriverKit companion")
        checksums.append(f"{proof['sha256']}  {name}")
    (directory / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
    (directory / (stem + ".SHA256SUMS")).write_text("\n".join(checksums) + "\n")
    names = sorted(
        [*expected_assets, *(name + ".build.json" for name in expected_assets), "SHA256SUMS", stem + ".SHA256SUMS"]
    )
    (directory / "release-assets.json").write_text(json.dumps(names, indent=2) + "\n")
    template = "RELEASE_NOTES_DEVELOPER_ID.md" if distribution == "developer-id" else "RELEASE_NOTES.md"
    (directory / "release-notes.md").write_text((REPO_ROOT / "configs" / template).read_text())
    print("Verified universal ZIP and DMG provenance and SHA-256 checksums.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("metadata", "verify"))
    parser.add_argument("--version", default=os.environ.get("RELEASE_VERSION", ""))
    parser.add_argument("--directory", type=Path, default=REPO_ROOT / "build/package")
    parser.add_argument(
        "--distribution",
        choices=("ad-hoc", "developer-id"),
        default=os.environ.get("BCR_RELEASE_DISTRIBUTION") or "ad-hoc",
    )
    parser.add_argument("--build-number", default=os.environ.get("ARCHIVE_ID", "1"))
    args = parser.parse_args(argv)
    version = release_version(args.version)
    if args.distribution not in {"ad-hoc", "developer-id"}:
        raise ValueError("Unknown release distribution; choose ad-hoc or developer-id explicitly")
    if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        raise ValueError("Invalid build number")
    if args.action == "metadata":
        if os.environ.get("GITHUB_OUTPUT"):
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
                stream.write(f"version={version}\n")
                stream.write(f"build_number={args.build_number}\ndistribution={args.distribution}\n")
        print(version)
    else:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True).strip()
        validate_assets(args.directory, version, commit, args.distribution, args.build_number)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
