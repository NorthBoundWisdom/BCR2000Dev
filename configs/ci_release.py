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


def validate_assets(directory: Path, version: str, commit: str) -> None:
    version = release_version(version)
    stem = f"{PRODUCT}_v{version}_1_macOS_universal_ad-hoc"
    expected_assets = {f"{stem}.zip", f"{stem}.dmg"}
    actual_assets = {p.name for p in directory.iterdir() if p.suffix in {".zip", ".dmg"}}
    if actual_assets != expected_assets:
        raise ValueError("Release requires exactly the expected universal ZIP and DMG.")
    checksums = []
    for name in sorted(expected_assets):
        asset = directory / name
        proof = json.loads(asset.with_suffix(asset.suffix + ".build.json").read_text())
        expected = {"schema_version": 1, "asset": name, "version": version, "build": "1",
                    "commit": commit, "dirty": False, "architecture": "universal",
                    "signature": "ad-hoc", "notarized": False, "sha256": _sha(asset)}
        if any(proof.get(key) != value for key, value in expected.items()):
            raise ValueError(f"Release artifact provenance/hash mismatch: {name}")
        checksums.append(f"{proof['sha256']}  {name}")
    (directory / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
    print("Verified universal ZIP and DMG provenance and SHA-256 checksums.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("metadata", "verify"))
    parser.add_argument("--version", default=os.environ.get("RELEASE_VERSION", ""))
    parser.add_argument("--directory", type=Path, default=REPO_ROOT / "build/package")
    args = parser.parse_args(argv)
    version = release_version(args.version)
    if args.action == "metadata":
        if os.environ.get("GITHUB_OUTPUT"):
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
                stream.write(f"version={version}\n")
        print(version)
    else:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True).strip()
        validate_assets(args.directory, version, commit)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
