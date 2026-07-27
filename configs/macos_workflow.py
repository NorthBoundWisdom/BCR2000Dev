#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_ROOT = REPO_ROOT / "build"
SWIFTPM_BUILD_ROOT = BUILD_ROOT / "swiftpm"
APP_ROOT = BUILD_ROOT / "app"
APP_BUNDLE = APP_ROOT / "BCRAgentConsole.app"
PACKAGE_ROOT = BUILD_ROOT / "package"
ACTIVE_LOCK = REPO_ROOT / "source_roots.lock.jsonc"
PRODUCT = "BCRAgentConsole"


def _run(command: list[str], *, capture: bool = False) -> str:
    print(">>", " ".join(command), flush=True)
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        text=True,
        capture_output=capture,
    )
    if completed.returncode != 0:
        if capture:
            if completed.stdout:
                print(completed.stdout)
            if completed.stderr:
                print(completed.stderr)
        raise RuntimeError(
            f"Command failed with exit code {completed.returncode}: {' '.join(command)}"
        )
    return completed.stdout.strip() if capture else ""


def _app_config() -> tuple[str, str]:
    if not ACTIVE_LOCK.is_file():
        raise RuntimeError(
            "Missing source_roots.lock.jsonc. Run `python3 configs/setup_local_project.py` first."
        )
    payload = json.loads(ACTIVE_LOCK.read_text(encoding="utf-8"))
    app_configs = payload.get("AppConfigs")
    if not isinstance(app_configs, dict):
        raise RuntimeError("source_roots.lock.jsonc is missing AppConfigs")

    version = app_configs.get("MARKETING_VERSION")
    archive_id = app_configs.get("ARCHIVE_ID")
    if not isinstance(version, str) or not version:
        raise RuntimeError("AppConfigs.MARKETING_VERSION must be a non-empty string")
    if not isinstance(archive_id, str) or not archive_id.isdigit():
        raise RuntimeError("AppConfigs.ARCHIVE_ID must be a numeric string")
    return version, archive_id


def _swift_build(configuration: str) -> Path:
    _app_config()
    _run(
        [
            "swift",
            "build",
            "--build-path",
            str(SWIFTPM_BUILD_ROOT),
            "--configuration",
            configuration,
            "--product",
            PRODUCT,
        ]
    )
    bin_path = Path(
        _run(
            [
                "swift",
                "build",
                "--build-path",
                str(SWIFTPM_BUILD_ROOT),
                "--configuration",
                configuration,
                "--show-bin-path",
            ],
            capture=True,
        )
    )
    executable = bin_path / PRODUCT
    if not executable.is_file():
        raise RuntimeError(f"Built executable not found: {executable}")
    return executable


def _write_bundle(executable: Path, *, version: str, archive_id: str) -> Path:
    if APP_BUNDLE.exists():
        shutil.rmtree(APP_BUNDLE)

    macos_dir = APP_BUNDLE / "Contents" / "MacOS"
    resources_dir = APP_BUNDLE / "Contents" / "Resources"
    macos_dir.mkdir(parents=True)
    resources_dir.mkdir(parents=True)

    bundled_executable = macos_dir / PRODUCT
    shutil.copy2(executable, bundled_executable)
    bundled_executable.chmod(0o755)

    info = {
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleDisplayName": "BCR Agent Console",
        "CFBundleExecutable": PRODUCT,
        "CFBundleIdentifier": "dev.bcragentconsole.app",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "BCR Agent Console",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": archive_id,
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    with (APP_BUNDLE / "Contents" / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=True)
    (APP_BUNDLE / "Contents" / "PkgInfo").write_text("APPL????", encoding="ascii")
    return APP_BUNDLE


def build(configuration: str) -> Path:
    version, archive_id = _app_config()
    executable = _swift_build(configuration)
    bundle = _write_bundle(executable, version=version, archive_id=archive_id)
    print(f"Built {bundle.relative_to(REPO_ROOT)}")
    return bundle


def test() -> None:
    _app_config()
    _run(
        [
            "swift",
            "test",
            "--build-path",
            str(SWIFTPM_BUILD_ROOT),
        ]
    )


def run() -> None:
    bundle = build("debug")
    executable = bundle / "Contents" / "MacOS" / PRODUCT
    completed = subprocess.run([str(executable)], cwd=REPO_ROOT)
    if completed.returncode != 0:
        raise RuntimeError(f"{PRODUCT} exited with code {completed.returncode}")


def package() -> Path:
    version, archive_id = _app_config()
    bundle = build("release")
    PACKAGE_ROOT.mkdir(parents=True, exist_ok=True)
    archive = PACKAGE_ROOT / f"BCRAgentConsole_v{version}_{archive_id}.zip"
    if archive.exists():
        archive.unlink()
    _run(
        [
            "ditto",
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            str(bundle),
            str(archive),
        ]
    )
    print(f"Packaged {archive.relative_to(REPO_ROOT)}")
    return archive


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="BCR Agent Console macOS workflow")
    parser.add_argument("action", choices=("build", "test", "run", "package"))
    parser.add_argument(
        "--configuration",
        choices=("debug", "release"),
        default="debug",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.action == "build":
        build(args.configuration)
    elif args.action == "test":
        test()
    elif args.action == "run":
        run()
    else:
        package()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
