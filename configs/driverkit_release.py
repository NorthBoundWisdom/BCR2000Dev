#!/usr/bin/env python3
"""Build/validate a Developer ID USB compatibility companion; never activate it."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import shutil
import re
import uuid
import hashlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from driverkit_probe import CLASS, DRIVER_ID, USB_ENTITLEMENT, build, info_plist, patch_configuration  # noqa: E402
from driverkit_xcode_project import generate  # noqa: E402

HOST_ID = "dev.bcragentconsole.descriptorprobe"
HOST_PRODUCT = "BCRUSBCompatibility"
# Public USB configuration for the supported BCR2000 firmware 1.10 / U-1 mode.
# No preset, control identity, user mapping, or MIDI capture is embedded here.
ORIGINAL_CONFIGURATION = bytes.fromhex(
    "090265000201004000090400000001010000092401000109000101090401000201030000"
    "07240100014100062402010100062402020200092403010301020100092403020401010100"
    "09058102400000000005250101030905020204000000000525010101"
)


def run(argv, *, text=True):
    result = subprocess.run([str(x) for x in argv], capture_output=True, text=text, timeout=300)
    if result.returncode:
        # Never include signing credentials or full profile content in exceptions.
        raise RuntimeError(f"{Path(str(argv[0])).name} failed ({result.returncode})")
    return result.stdout


def decode_profile(path):
    return plistlib.loads(run(["security", "cms", "-D", "-i", path], text=False))


def validate_profile(profile, bundle_id, *, driver=False, now=None):
    """Metadata gate, followed by actual signature/notary/Gatekeeper checks."""
    now = now or datetime.now(timezone.utc)
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        raise ValueError("Profile has no expiration")
    expiration = expiration.replace(tzinfo=timezone.utc) if expiration.tzinfo is None else expiration
    if expiration <= now:
        raise ValueError("Profile expired")
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices") is not True:
        raise ValueError("A Developer ID distribution profile is required; development/device-bound profiles rejected")
    try:
        uuid.UUID(profile["UUID"])
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise ValueError("Invalid provisioning profile UUID") from error
    ent = profile.get("Entitlements", {})
    if ent.get("get-task-allow") or ent.get("com.apple.security.get-task-allow"):
        raise ValueError("Debugging grants are not permitted in a release")
    team = ent.get("com.apple.developer.team-identifier")
    if not isinstance(team, str) or profile.get("TeamIdentifier") != [team]:
        raise ValueError("Profile team mismatch")
    app = ent.get("com.apple.application-identifier", ent.get("application-identifier"))
    if app != team + "." + bundle_id:
        raise ValueError("Profile must cover the exact bundle identifier")
    if driver:
        grants = ent.get(USB_ENTITLEMENT)
        if ent.get("com.apple.developer.driverkit") is not True or not isinstance(grants, list) or len(grants) != 1:
            raise ValueError("Missing narrowly scoped DriverKit USB release grant")
        grant = grants[0]
        if not isinstance(grant, dict) or set(grant) - {"idVendor", "idProduct"}:
            raise ValueError("Unsupported USB grant shape")
        if type(grant.get("idVendor")) is not int or grant["idVendor"] != 0x1397:
            raise ValueError("USB release grant must name vendor 0x1397; development wildcard rejected")
        if "idProduct" in grant and (type(grant["idProduct"]) is not int or grant["idProduct"] != 0x00BC):
            raise ValueError("USB release grant does not cover BCR2000")
    elif ent.get("com.apple.developer.system-extension.install") is not True:
        raise ValueError("Host profile lacks system-extension install grant")
    return team


def signing_entitlements(bundle):
    data = run(["codesign", "-d", "--entitlements", "-", bundle], text=False)
    return plistlib.loads(data) if data.strip() else {}


def verify_developer_id(bundle):
    run(["codesign", "--verify", "--strict", "--deep", bundle])
    result = subprocess.run(["codesign", "-dv", "--verbose=4", str(bundle)], capture_output=True, text=True)
    details = result.stderr
    if (
        result.returncode
        or "Authority=Developer ID Application:" not in details
        or "runtime" not in details
        or "Timestamp=" not in details
    ):
        raise ValueError("Expected timestamped, hardened Developer ID signature")
    ent = signing_entitlements(bundle)
    if ent.get("get-task-allow") or ent.get("com.apple.security.get-task-allow"):
        raise ValueError("Signed release contains debugging entitlement")
    return ent.get("com.apple.developer.team-identifier")


def verify_companion(bundle, version, build_number):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (
        HOST_ID,
        version,
        build_number,
    ):
        raise ValueError("Compatibility host identity/version mismatch")
    if info.get("CFBundleExecutable") != "BCRDriverKitProbe" or info.get("BCRProbeLabMode") is not False:
        raise ValueError("Expected the production-mode compatibility host")
    extensions = list((bundle / "Contents/Library/SystemExtensions").glob("*.dext"))
    if len(extensions) != 1 or extensions[0].name != DRIVER_ID + ".dext":
        raise ValueError("Expected exactly the approved compatibility extension")
    driver = extensions[0]
    di = plistlib.loads((driver / "Info.plist").read_bytes())
    patched, _ = patch_configuration(ORIGINAL_CONFIGURATION)
    expected = info_plist("override", patched)["IOKitPersonalities"]
    if di.get("IOKitPersonalities") != expected:
        raise ValueError("Unexpected matching scope or descriptor payload")
    if (di.get("CFBundleIdentifier"), di.get("CFBundleShortVersionString"), di.get("CFBundleVersion")) != (
        DRIVER_ID,
        version,
        build_number,
    ):
        raise ValueError("Compatibility driver identity/version mismatch")
    if di.get("CFBundleExecutable") != CLASS:
        raise ValueError("Unexpected compatibility driver executable")
    hp = decode_profile(bundle / "Contents/embedded.provisionprofile")
    dp = decode_profile(driver / "embedded.provisionprofile")
    team = validate_profile(hp, HOST_ID)
    if validate_profile(dp, DRIVER_ID, driver=True) != team:
        raise ValueError("Host and driver profiles must use the same team")
    for target, profile in ((bundle, hp), (driver, dp)):
        if verify_developer_id(target) != team:
            raise ValueError("Signature/profile team mismatch")
        signed = signing_entitlements(target)
        if target == bundle and signed.get("com.apple.developer.system-extension.install") is not True:
            raise ValueError("Signed compatibility host lacks the install grant")
        if target == driver and signed.get("com.apple.developer.driverkit") is not True:
            raise ValueError("Signed compatibility driver lacks the DriverKit grant")
        if target == driver and signed.get(USB_ENTITLEMENT) != profile["Entitlements"][USB_ENTITLEMENT]:
            raise ValueError("Signed USB grant differs from approved profile")
    for executable in (bundle / "Contents/MacOS/BCRDriverKitProbe", driver / CLASS):
        if set(run(["lipo", "-archs", executable]).split()) != {"arm64", "x86_64"}:
            raise ValueError("Compatibility component is not universal")
        for line in run(["otool", "-L", executable]).splitlines():
            if line.startswith("\t") and not line.strip().split(" (", 1)[0].startswith(
                ("/System/Library/", "/System/DriverKit/", "/usr/lib/")
            ):
                raise ValueError("Undeployed non-system compatibility dependency")
    return {"host": HOST_PRODUCT + ".app", "bundle_id": DRIVER_ID, "signature": "developer-id", "supported_mode": "U-1"}


def build_companion(host_profile, driver_profile, identity, version, build_number):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version) or not re.fullmatch(
        r"[1-9][0-9]*", build_number
    ):
        raise ValueError("Invalid release version/build number")
    hp, dp = decode_profile(host_profile), decode_profile(driver_profile)
    team = validate_profile(hp, HOST_ID)
    if validate_profile(dp, DRIVER_ID, driver=True) != team:
        raise ValueError("Release profiles use different teams")
    profiles = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    profiles.mkdir(parents=True, exist_ok=True)
    for source, profile in ((host_profile, hp), (driver_profile, dp)):
        destination = profiles / (profile["UUID"] + ".provisionprofile")
        if destination.exists() and destination.read_bytes() != source.read_bytes():
            raise ValueError("Existing profile UUID has different content; refusing overwrite")
        if not destination.exists():
            shutil.copyfile(source, destination)
            if os.environ.get("RUNNER_TEMP"):
                state_file = Path(os.environ["RUNNER_TEMP"]) / "bcr-signing-state.json"
                if state_file.exists():
                    state = json.loads(state_file.read_text())
                    state.setdefault("installedProfiles", []).append(
                        {"path": str(destination), "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}
                    )
                    state_file.write_text(json.dumps(state))
    output = ROOT / "build/driverkit-release"
    output.mkdir(parents=True, exist_ok=True)
    report = {
        "targets": [
            {
                "vendor": 0x1397,
                "product": 0xBC,
                "USBSpeed": 1,
                "bcdDevice": 0x100,
                "cachedConfiguration": {
                    "status": "ok",
                    "currentConfiguration": 1,
                    "configurationHex": ORIGINAL_CONFIGURATION.hex(),
                },
            }
        ]
    }
    source = output / "usb-configuration.json"
    source.write_text(json.dumps(report))
    build(source, output)
    project = generate(output, team, "override")
    root = project.parent
    info = plistlib.loads((root / "Host-Info.plist").read_bytes())
    info.update(
        CFBundleName="BCR USB Compatibility",
        CFBundleDisplayName="BCR USB Compatibility",
        CFBundleShortVersionString=version,
        CFBundleVersion=build_number,
        BCRProbeLabMode=False,
    )
    (root / "Host-Info.plist").write_bytes(plistlib.dumps(info))
    di = plistlib.loads((root / "Driver-Info.plist").read_bytes())
    di.update(
        CFBundleShortVersionString=version, CFBundleVersion=build_number, CFBundleName="BCR USB Compatibility Driver"
    )
    (root / "Driver-Info.plist").write_bytes(plistlib.dumps(di))
    for name, ent in (
        (
            "Driver-Release.entitlements",
            {"com.apple.developer.driverkit": True, USB_ENTITLEMENT: dp["Entitlements"][USB_ENTITLEMENT]},
        ),
        ("Host-Release.entitlements", {"com.apple.developer.system-extension.install": True}),
    ):
        profile = dp if name.startswith("Driver") else hp
        ent.update(
            {
                key: value
                for key, value in profile["Entitlements"].items()
                if key
                in {"com.apple.application-identifier", "application-identifier", "com.apple.developer.team-identifier"}
            }
        )
        (root / name).write_bytes(plistlib.dumps(ent))
    data = plistlib.loads((project / "project.pbxproj").read_bytes())
    for obj in data["objects"].values():
        if obj["isa"] == "XCBuildConfiguration":
            obj["name"] = "Release"
            settings = obj["buildSettings"]
            settings.update(
                CODE_SIGN_STYLE="Manual",
                CODE_SIGN_IDENTITY=identity,
                CODE_SIGN_INJECT_BASE_ENTITLEMENTS="NO",
                OTHER_CODE_SIGN_FLAGS="--timestamp",
                ENABLE_TESTABILITY="NO",
                SWIFT_OPTIMIZATION_LEVEL="-O",
            )
            if settings.get("SDKROOT") in {"driverkit", "macosx"}:
                driver = settings["SDKROOT"] == "driverkit"
                settings["PROVISIONING_PROFILE_SPECIFIER"] = (dp if driver else hp)["UUID"]
                settings["CODE_SIGN_ENTITLEMENTS"] = ("Driver" if driver else "Host") + "-Release.entitlements"
        elif obj["isa"] == "XCConfigurationList":
            obj["defaultConfigurationName"] = "Release"
    (project / "project.pbxproj").write_bytes(plistlib.dumps(data))
    derived = output / "derived"
    result = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(project),
            "-scheme",
            "BCRDriverKitProbe",
            "-configuration",
            "Release",
            "-derivedDataPath",
            str(derived),
            "ARCHS=arm64 x86_64",
            "ONLY_ACTIVE_ARCH=NO",
            "build",
        ],
        stdout=(output / "build.log").open("w"),
        stderr=subprocess.STDOUT,
    )
    if result.returncode:
        raise RuntimeError("Compatibility release build failed; see private build/driverkit-release/build.log")
    app = derived / "Build/Products/Release/BCRDriverKitProbe.app"
    verify_companion(app, version, build_number)
    print(app)
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["preflight", "build"])
    parser.add_argument("--host-profile", type=Path, default=os.environ.get("BCR_DRIVERKIT_HOST_PROFILE"))
    parser.add_argument("--driver-profile", type=Path, default=os.environ.get("BCR_DRIVERKIT_PROFILE"))
    parser.add_argument("--identity", default=os.environ.get("BCR_SIGNING_IDENTITY"))
    parser.add_argument("--version", default=os.environ.get("MARKETING_VERSION", "0.1.0"))
    parser.add_argument("--build-number", default=os.environ.get("ARCHIVE_ID", "1"))
    args = parser.parse_args()
    if not args.host_profile or not args.driver_profile:
        raise ValueError("Approved Developer ID profiles for both compatibility host and driver are required")
    hp, dp = decode_profile(args.host_profile), decode_profile(args.driver_profile)
    team = validate_profile(hp, HOST_ID)
    if validate_profile(dp, DRIVER_ID, driver=True) != team:
        raise ValueError("Profiles use different teams")
    if args.action == "preflight":
        print("Approved, unexpired Developer ID profile metadata passed; no signing or activation attempted.")
    else:
        if not args.identity:
            raise ValueError("Explicit Developer ID signing identity required")
        build_companion(args.host_profile, args.driver_profile, args.identity, args.version, args.build_number)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
