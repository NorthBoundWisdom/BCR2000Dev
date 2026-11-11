#!/usr/bin/env python3
"""Build, sign, package and verify the native macOS application."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.app_build import load_app_build_settings  # noqa: E402
from configs.build_environment import use_build_environment  # noqa: E402

BUILD_ROOT = REPO_ROOT / "build"
SWIFTPM_BUILD_ROOT = BUILD_ROOT / "swiftpm"
APP_BUNDLE = BUILD_ROOT / "app/BCRAgentConsole.app"
PACKAGE_ROOT = BUILD_ROOT / "package"
PRODUCT = "BCRAgentConsole"
BUNDLE_ID = "dev.bcragentconsole.app"
SMOKE_MARKER = '"type":"bcr.native_startup"'


def _run(command: list[str | Path], *, capture: bool = False, cwd: Path = REPO_ROOT, timeout: int | None = None) -> str:
    command = [str(part) for part in command]
    print(">>", " ".join(command), flush=True)
    completed = subprocess.run(command, cwd=cwd, text=True, capture_output=capture, timeout=timeout)
    if completed.returncode:
        if capture:
            print(completed.stdout, file=sys.stderr)
            print(completed.stderr, file=sys.stderr)
        raise RuntimeError(f"Command failed ({completed.returncode}): {command[0]}")
    return completed.stdout.strip() if capture else ""


def _architectures(architecture: str) -> tuple[str, ...]:
    if architecture == "universal":
        return ("arm64", "x86_64")
    return (platform.machine() if architecture == "native" else architecture,)


def _swift_build(configuration: str, architecture: str) -> Path:
    binaries = []
    for arch in _architectures(architecture):
        if arch not in {"arm64", "x86_64"}:
            raise ValueError(f"Unsupported macOS architecture: {arch}")
        options = [
            "swift",
            "build",
            "--build-path",
            str(SWIFTPM_BUILD_ROOT / arch),
            "--configuration",
            configuration,
            "--triple",
            f"{arch}-apple-macosx14.0",
        ]
        _run([*options, "--product", PRODUCT])
        binary = Path(_run([*options, "--show-bin-path"], capture=True)) / PRODUCT
        if not binary.is_file():
            raise RuntimeError(f"Built executable not found: {binary}")
        binaries.append(binary)
    if len(binaries) == 1:
        return binaries[0]
    output = SWIFTPM_BUILD_ROOT / "universal" / configuration / PRODUCT
    output.parent.mkdir(parents=True, exist_ok=True)
    _run(["lipo", "-create", *binaries, "-output", output])
    # Resource bundles are architecture-independent, but must also accompany the lipo output.
    localization = binaries[0].parent / "BCRAgentConsole_BCRFoundation.bundle"
    shutil.copytree(localization, output.parent / localization.name, dirs_exist_ok=True)
    return output


def _build_icon() -> Path:
    source = REPO_ROOT / "assets/AppIcon.png"
    if not source.is_file():
        raise ValueError("Missing assets/AppIcon.png")
    iconset = BUILD_ROOT / "icons/AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            suffix = "@2x" if scale == 2 else ""
            _run(
                ["sips", "-z", str(pixels), str(pixels), source, "--out", iconset / f"icon_{size}x{size}{suffix}.png"],
                capture=True,
            )
    output = iconset.parent / "AppIcon.icns"
    _run(["iconutil", "-c", "icns", iconset, "-o", output])
    return output


def _sign(bundle: Path, distribution: str, identity: str | None, *, hardened: bool = True) -> None:
    if distribution == "ad-hoc":
        command = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    else:
        identity = identity or os.environ.get("BCR_SIGNING_IDENTITY", "")
        prefix = "Developer ID Application:" if distribution == "developer-id" else "Apple Development:"
        identities = _run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True)
        matches = []
        for line in identities.splitlines():
            parts = line.strip().split('"')
            if len(parts) >= 3 and parts[1].startswith(prefix):
                sha = parts[0].split()[-1]
                if not identity or identity in (sha, parts[1]):
                    matches.append(sha)
        if len(matches) != 1:
            raise ValueError(f"Select exactly one {prefix} identity with --identity or BCR_SIGNING_IDENTITY.")
        command = [
            "codesign",
            "--force",
            "--sign",
            matches[0],
            *(["--options", "runtime"] if hardened else []),
            "--timestamp" if distribution == "developer-id" else "--timestamp=none",
        ]
    # The companion builder signs its nested driver first. Sign this payload/container explicitly.
    _run([*command, bundle])
    _run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle])


def build(
    configuration: str, architecture: str = "native", distribution: str = "ad-hoc", identity: str | None = None
) -> Path:
    settings = load_app_build_settings()
    executable = _swift_build(configuration, architecture)
    icon = _build_icon()
    if APP_BUNDLE.exists():
        shutil.rmtree(APP_BUNDLE)
    macos = APP_BUNDLE / "Contents/MacOS"
    resources = APP_BUNDLE / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(executable, macos / PRODUCT)
    (macos / PRODUCT).chmod(0o755)
    shutil.copy2(icon, resources / "AppIcon.icns")
    localization = executable.parent / "BCRAgentConsole_BCRFoundation.bundle"
    if not localization.is_dir():
        raise ValueError("SwiftPM localization resource bundle is missing.")
    shutil.copytree(localization, resources / localization.name)
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": ["en", "zh-Hans"],
        "CFBundleDisplayName": "BCR Agent Console",
        "CFBundleExecutable": PRODUCT,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "BCR Agent Console",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": settings["MARKETING_VERSION"],
        "CFBundleVersion": settings["ARCHIVE_ID"],
        "CFBundleIconFile": "AppIcon.icns",
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        "BCRDistribution": distribution,
    }
    (APP_BUNDLE / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    (APP_BUNDLE / "Contents/PkgInfo").write_text("APPL????", encoding="ascii")
    _sign(APP_BUNDLE, distribution, identity)
    verify_bundle(APP_BUNDLE)
    print(f"Built {APP_BUNDLE.relative_to(REPO_ROOT)}")
    return APP_BUNDLE


def verify_bundle(bundle: Path) -> dict:
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if (
        info.get("CFBundleIdentifier") != BUNDLE_ID
        or info.get("CFBundleExecutable") != PRODUCT
        or info.get("CFBundleIconFile") != "AppIcon.icns"
        or info.get("LSMinimumSystemVersion") != "14.0"
    ):
        raise ValueError("Unexpected app bundle metadata.")
    if not (bundle / "Contents/Resources/AppIcon.icns").is_file():
        raise ValueError("Packaged application icon is missing.")
    if info.get("CFBundleLocalizations") != ["en", "zh-Hans"]:
        raise ValueError("Application language metadata is missing.")
    localization = bundle / "Contents/Resources/BCRAgentConsole_BCRFoundation.bundle"
    for language in ("en", "zh-Hans"):
        candidates = [localization / "Contents/Resources", localization]
        if not any((root / f"{language}.lproj/Localizable.strings").is_file() for root in candidates):
            raise ValueError(f"Bundled {language} translations are missing.")
    executable = bundle / "Contents/MacOS" / PRODUCT
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("Packaged executable is missing or not executable.")
    _run(["codesign", "--verify", "--deep", "--strict", bundle])
    # Reject dependencies that would work only on the build machine.
    dependencies = _run(["otool", "-L", executable], capture=True)
    for line in dependencies.splitlines():
        if not line.startswith("\t"):
            continue
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/System/Library/", "/usr/lib/")):
            raise ValueError(f"Non-system runtime dependency requires deployment: {dependency}")
    return info


def smoke(bundle: Path) -> None:
    info = verify_bundle(bundle)
    executable = (bundle / "Contents/MacOS" / PRODUCT).resolve()
    for language, settings_title in (("en", "Settings"), ("zh-Hans", "设置")):
        with tempfile.TemporaryDirectory(prefix="bcr-startup-") as temporary:
            # Argument-domain language overrides never modify user preferences.
            result = subprocess.run(
                [str(executable), "--startup-smoke", "-AppleLanguages", f"({language})"],
                cwd=temporary,
                text=True,
                capture_output=True,
                timeout=40,
            )
        if result.returncode or SMOKE_MARKER not in result.stdout:
            raise RuntimeError(f"Native window startup failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
        marker = next(json.loads(line) for line in result.stdout.splitlines() if SMOKE_MARKER in line)
        if marker.get("clientVersion") != info["CFBundleShortVersionString"]:
            raise RuntimeError("Native client version does not match the packaged app metadata.")
        if marker.get("language") != language or marker.get("settings") != settings_title:
            raise RuntimeError(f"Bundled {language} localization did not resolve correctly: {marker}")
    print("Verified English and Chinese native startup at 1200 × 760 with bundled icon and translations.")


def _zip(bundle: Path, destination: Path, companion: Path | None = None) -> None:
    if destination.exists():
        destination.unlink()
    if companion:
        with tempfile.TemporaryDirectory(dir=BUILD_ROOT, prefix="zip-layout-") as temporary:
            layout = Path(temporary)
            shutil.copytree(bundle, layout / bundle.name, symlinks=True)
            shutil.copytree(companion, layout / companion.name, symlinks=True)
            _run(["ditto", "-c", "-k", "--sequesterRsrc", layout, destination])
        return
    _run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, destination])


def _dmg(bundle: Path, destination: Path, companion: Path | None = None) -> None:
    stage = BUILD_ROOT / "package-staging"
    stage.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=stage, prefix="dmg-") as temporary:
        layout = Path(temporary)
        shutil.copytree(bundle, layout / bundle.name, symlinks=True)
        if companion:
            shutil.copytree(companion, layout / companion.name, symlinks=True)
        (layout / "Applications").symlink_to("/Applications")
        _run(
            [
                "hdiutil",
                "create",
                "-volname",
                "BCR Agent Console",
                "-srcfolder",
                layout,
                "-ov",
                "-format",
                "UDZO",
                destination,
            ]
        )


def _notarize(archive: Path, profile: str) -> None:
    keychain = os.environ.get("BCR_NOTARY_KEYCHAIN")
    result = json.loads(
        _run(
            [
                "xcrun",
                "notarytool",
                "submit",
                archive,
                "--keychain-profile",
                profile,
                *(["--keychain", keychain] if keychain else []),
                "--wait",
                "--output-format",
                "json",
            ],
            capture=True,
        )
    )
    if result.get("status") != "Accepted":
        raise RuntimeError(f"Notarization failed: {result}")


def _staple(target: Path) -> None:
    _run(["xcrun", "stapler", "staple", target])
    _run(["xcrun", "stapler", "validate", target])


def _sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _write_records(assets: list[Path], architecture: str, distribution: str, driverkit: dict | None = None) -> None:
    settings = load_app_build_settings()
    commit = _run(["git", "rev-parse", "HEAD"], capture=True)
    dirty = bool(_run(["git", "status", "--porcelain"], capture=True))
    swift = _run(["swift", "--version"], capture=True)
    checksums = []
    for asset in assets:
        checksum = _sha(asset)
        record = {
            "schema_version": 1,
            "asset": asset.name,
            "sha256": checksum,
            "version": settings["MARKETING_VERSION"],
            "build": settings["ARCHIVE_ID"],
            "commit": commit,
            "dirty": dirty,
            "architecture": architecture,
            "signature": distribution,
            "notarized": distribution == "developer-id",
            "minimum_macos": "14.0",
            "swift": swift,
        }
        if driverkit:
            record["driverkit"] = {**driverkit, "notarized": True}
        asset.with_suffix(asset.suffix + ".build.json").write_text(json.dumps(record, indent=2) + "\n")
        checksums.append(f"{checksum}  {asset.name}")
    # Per-build checksums avoid accidentally publishing artifacts left by a previous version.
    checksum_name = assets[0].name.rsplit(".", 1)[0] + ".SHA256SUMS"
    (PACKAGE_ROOT / checksum_name).write_text("\n".join(checksums) + "\n")


def package(
    architecture: str = "native",
    distribution: str = "ad-hoc",
    identity: str | None = None,
    notary_profile: str | None = None,
    package_format: str = "both",
    driverkit_host: Path | None = None,
) -> list[Path]:
    profile = notary_profile or os.environ.get("BCR_NOTARY_KEYCHAIN_PROFILE", "")
    if distribution == "developer-id" and (not profile or any(c in profile for c in "\r\n\0")):
        raise ValueError("Developer ID packaging requires --notary-profile or BCR_NOTARY_KEYCHAIN_PROFILE.")
    settings = load_app_build_settings()
    companion = None
    driverkit = None
    if driverkit_host:
        if distribution != "developer-id" or architecture != "universal":
            raise ValueError("A DriverKit release requires universal Developer ID packaging")
        from configs.driverkit_release import HOST_PRODUCT, verify_companion

        driverkit = verify_companion(driverkit_host, settings["MARKETING_VERSION"], settings["ARCHIVE_ID"])
    bundle = build("release", architecture, distribution, identity)
    if driverkit_host:
        companion = bundle.parent / (HOST_PRODUCT + ".app")
        if companion.resolve() == driverkit_host.resolve():
            raise ValueError("Compatibility input must be outside the packaging staging directory")
        if companion.exists():
            shutil.rmtree(companion)
        shutil.copytree(driverkit_host, companion, symlinks=True)
    if platform.machine() in _architectures(architecture):
        smoke(bundle)
    PACKAGE_ROOT.mkdir(parents=True, exist_ok=True)
    arch = "universal" if architecture == "universal" else _architectures(architecture)[0]
    stem = f"{PRODUCT}_v{settings['MARKETING_VERSION']}_{settings['ARCHIVE_ID']}_macOS_{arch}_{distribution}"
    if distribution == "developer-id":
        # Notarize/staple the app first so both ZIP and DMG contain an offline-verifiable app.
        with tempfile.TemporaryDirectory(dir=BUILD_ROOT, prefix="notary-") as temporary:
            submission = Path(temporary) / "submission.zip"
            _zip(bundle, submission, companion)
            _notarize(submission, profile)
        _staple(bundle)
        _run(["spctl", "--assess", "--type", "execute", "--verbose=2", bundle])
        if companion:
            _staple(companion)
            _run(["spctl", "--assess", "--type", "execute", "--verbose=2", companion])
    assets = []
    if package_format in {"zip", "both"}:
        archive = PACKAGE_ROOT / f"{stem}.zip"
        _zip(bundle, archive, companion)
        assets.append(archive)
    if package_format in {"dmg", "both"}:
        archive = PACKAGE_ROOT / f"{stem}.dmg"
        _dmg(bundle, archive, companion)
        if distribution == "developer-id":
            _sign(archive, distribution, identity, hardened=False)
            _notarize(archive, profile)
            _staple(archive)
            _run(
                [
                    "spctl",
                    "--assess",
                    "--type",
                    "open",
                    "--context",
                    "context:primary-signature",
                    "--verbose=2",
                    archive,
                ]
            )
        assets.append(archive)
    _write_records(assets, arch, distribution, driverkit)
    for asset in assets:
        print(f"Packaged {asset.relative_to(REPO_ROOT)}")
    return assets


def check_package(archive: Path) -> None:
    archive = archive.resolve()
    proof = json.loads(archive.with_suffix(archive.suffix + ".build.json").read_text())
    if proof.get("asset") != archive.name or proof.get("sha256") != _sha(archive):
        raise ValueError("Release artifact hash/provenance mismatch.")
    with tempfile.TemporaryDirectory(prefix="bcr-package-") as temporary:
        root = Path(temporary)
        if archive.suffix == ".zip":
            _run(["ditto", "-x", "-k", archive, root])
            bundle = root / f"{PRODUCT}.app"
            _check_payload(bundle, proof)
            _check_companion(root, proof)
        elif archive.suffix == ".dmg":
            if proof.get("notarized"):
                _run(["codesign", "--verify", "--strict", archive])
                _run(["xcrun", "stapler", "validate", archive])
                _run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", archive])
            mount = root / "mounted"
            _run(["hdiutil", "attach", archive, "-readonly", "-nobrowse", "-mountpoint", mount])
            try:
                if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
                    raise ValueError("Installer is missing the Applications shortcut.")
                bundle = root / f"{PRODUCT}.app"
                _run(["ditto", mount / f"{PRODUCT}.app", bundle])
                _check_payload(bundle, proof)
                _check_companion(mount, proof)
            finally:
                _run(["hdiutil", "detach", mount])
        else:
            raise ValueError("Expected a ZIP or DMG package.")
    print(f"Verified package: {archive.name}")


def _check_companion(root: Path, proof: dict) -> None:
    from configs.driverkit_release import HOST_PRODUCT, verify_companion

    companion = root / (HOST_PRODUCT + ".app")
    if proof.get("driverkit"):
        metadata = verify_companion(companion, proof["version"], proof["build"])
        if proof["driverkit"] != {**metadata, "notarized": True}:
            raise ValueError("Compatibility companion differs from release record")
        _run(["xcrun", "stapler", "validate", companion])
        _run(["spctl", "--assess", "--type", "execute", companion])
        result = _run([companion / "Contents/MacOS/BCRDriverKitProbe", "--startup-smoke"], capture=True, timeout=40)
        if (
            '"type":"bcr.usb_compatibility_startup"' not in result
            or '"hardwareAccessed":false' not in result
            or '"labMode":false' not in result
        ):
            raise RuntimeError("Compatibility companion native startup failed")
    elif companion.exists():
        raise ValueError("Unexpected compatibility companion without a release record")


def _check_payload(bundle: Path, proof: dict) -> None:
    info = verify_bundle(bundle)
    if (
        info["CFBundleShortVersionString"] != proof["version"]
        or info["CFBundleVersion"] != proof["build"]
        or info["BCRDistribution"] != proof["signature"]
    ):
        raise ValueError("Package metadata differs from build record.")
    archs = _run(["lipo", "-archs", bundle / "Contents/MacOS" / PRODUCT], capture=True).split()
    if set(archs) != set(_architectures(proof["architecture"])):
        raise ValueError("Packaged executable architectures differ from build record.")
    if proof.get("notarized"):
        from configs.driverkit_release import verify_developer_id

        verify_developer_id(bundle)
        _run(["xcrun", "stapler", "validate", bundle])
        _run(["spctl", "--assess", "--type", "execute", bundle])
    if platform.machine() in archs:
        smoke(bundle)
    else:
        print(f"Startup requires a {', '.join(archs)} host; structural verification passed.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "test", "run", "package", "smoke", "check-package"))
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--architecture", choices=("native", "arm64", "x86_64", "universal"), default="native")
    parser.add_argument("--distribution", choices=("ad-hoc", "development", "developer-id"), default="ad-hoc")
    parser.add_argument("--identity", help="Signing certificate name or SHA-1; otherwise BCR_SIGNING_IDENTITY.")
    parser.add_argument("--notary-profile", help="notarytool Keychain profile; otherwise BCR_NOTARY_KEYCHAIN_PROFILE.")
    parser.add_argument("--format", choices=("zip", "dmg", "both"), default="both")
    parser.add_argument("--bundle", type=Path, default=APP_BUNDLE, help="Bundle for the smoke action.")
    parser.add_argument("--archive", type=Path, help="ZIP/DMG for check-package (with .build.json sidecar).")
    parser.add_argument("--driverkit-host", type=Path, help="Approved Developer ID compatibility companion to include.")
    args = parser.parse_args(argv)
    with use_build_environment(REPO_ROOT):
        if sys.platform != "darwin":
            parser.error("This workflow requires macOS and Xcode's Swift 6 toolchain.")
        if args.action == "test":
            _run(["swift", "test", "--build-path", SWIFTPM_BUILD_ROOT])
        elif args.action == "package":
            package(
                args.architecture,
                args.distribution,
                args.identity,
                args.notary_profile,
                args.format,
                args.driverkit_host,
            )
        elif args.action == "smoke":
            smoke(args.bundle)
        elif args.action == "check-package":
            if args.archive is None:
                parser.error("check-package requires --archive")
            check_package(args.archive)
        else:
            bundle = build(args.configuration, args.architecture, args.distribution, args.identity)
            if args.action == "run":
                _run([bundle / "Contents/MacOS" / PRODUCT])
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
