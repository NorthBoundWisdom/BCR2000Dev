#!/usr/bin/env python3
"""Compile-only codeless dext experiment and read-only signing audit.

Never activates an extension, signs a driver, requests profiles, changes SIP,
loads a kext, changes USB configuration, or sends MIDI. Generated artifacts and
private provisioning metadata stay under ignored build/.
"""

import argparse
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

from diagnostic_io import write_json

ROOT = Path(__file__).resolve().parents[1]
DRIVER_ID = "dev.bcragentconsole.descriptorprobe.driver"
CLASS = "BCRDescriptorProbe"
USB_ENTITLEMENT = "com.apple.developer.driverkit.transport.usb"


def provisioning_udid(hardware):
    # Apple Silicon registration uses Provisioning UDID, not Hardware UUID.
    value = hardware.get("provisioning_UDID") or hardware.get("platform_UUID")
    if not isinstance(value, str) or not value:
        raise ValueError("No provisioning device identifier")
    return value


def patch_configuration(raw):
    """Change only the MPS of one FS MIDI Streaming bulk OUT 0x02, 4 -> 8."""
    if len(raw) < 9 or len(raw) > 4096 or raw[:2] != bytes([9, 2]):
        raise ValueError("Invalid configuration descriptor")
    if int.from_bytes(raw[2:4], "little") != len(raw):
        raise ValueError("Configuration length mismatch")
    offset, midi_interface, candidates, inputs = 0, False, [], 0
    while offset < len(raw):
        length = raw[offset]
        if length < 2 or offset + length > len(raw):
            raise ValueError("Truncated or zero-length descriptor")
        kind = raw[offset + 1]
        if kind == 4:
            if length < 9:
                raise ValueError("Truncated interface")
            midi_interface = raw[offset + 2 : offset + 4] == bytes([1, 0]) and raw[offset + 5 : offset + 7] == bytes(
                [1, 3]
            )
        if kind == 5 and midi_interface:
            if length < 7:
                raise ValueError("Truncated endpoint")
            address, attributes = raw[offset + 2 : offset + 4]
            packet = int.from_bytes(raw[offset + 4 : offset + 6], "little")
            if address == 0x02:
                if attributes & 3 != 2 or packet != 4:
                    raise ValueError("Expected unmodified bulk OUT 0x02 with MPS 4")
                candidates.append(offset + 4)
            if address == 0x81 and attributes & 3 == 2 and packet == 64:
                inputs += 1
        offset += length
    if len(candidates) != 1 or inputs != 1:
        raise ValueError("Need one matching MIDI IN and OUT endpoint")
    patched = bytearray(raw)
    patched[candidates[0]] = 8
    return bytes(patched), candidates[0]


def configuration_from_report(report):
    targets = report.get("targets", [])
    if len(targets) != 1:
        raise ValueError("Need exactly one BCR USB device")
    target = targets[0]
    for key, expected in {"vendor": 0x1397, "product": 0x00BC, "USBSpeed": 1, "bcdDevice": 0x0100}.items():
        if type(target.get(key)) is not int or target[key] != expected:
            raise ValueError("Unsupported device identity/speed/release: " + key)
    cached = target.get("cachedConfiguration", {})
    if cached.get("status") != "ok" or cached.get("currentConfiguration") != 1:
        raise ValueError("Need verified cached configuration 1")
    raw = bytes.fromhex(cached["configurationHex"])
    patch_configuration(raw)
    return raw


def info_plist(variant, patched):
    if variant not in {"control", "override"}:
        raise ValueError("Unknown experiment variant")
    properties = {"BCRDescriptorProbeVersion": variant + "-v1"}
    if variant == "override":
        properties["kUSBDescriptorOverride"] = {"descriptor": patched, "index": 0, "languageID": 0}
    return {
        "CFBundleIdentifier": DRIVER_ID,
        "CFBundleExecutable": CLASS,
        "CFBundleName": CLASS,
        "CFBundlePackageType": "DEXT",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1" if variant == "control" else "2",
        "OSBundleUsageDescription": "验证 BCR2000 主机 USB 描述兼容性，不修改固件或预设。",
        "IOKitPersonalities": {
            CLASS: {
                "CFBundleIdentifier": DRIVER_ID,
                # Device-level merge personality follows Apple's TN3190 example.
                # Support/timing of kUSBDescriptorOverride in a dext remains unproven.
                "CFBundleIdentifierKernel": "com.apple.driver.AppleUSBMergeNub",
                "IOClass": "AppleUSBMergeNub",
                "IOProviderClass": "IOUSBHostDevice",
                "IOUserClass": CLASS,
                "IOUserServerName": DRIVER_ID,
                "IOProbeScore": 10000,
                "idVendor": 0x1397,
                "idProduct": 0x00BC,
                "bcdDevice": 0x0100,
                "IOProviderMergeProperties": properties,
            }
        },
    }


def profile_candidate(profile, now):
    """An entitlement candidate, never a claim of platform trust or installability."""
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        return False
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if expiration <= now:
        return False
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("com.apple.developer.driverkit") is not True:
        return False
    app_id = entitlements.get("application-identifier", entitlements.get("com.apple.application-identifier", ""))
    if not isinstance(app_id, str) or "." not in app_id:
        return False
    if not fnmatch.fnmatchcase(DRIVER_ID, app_id.split(".", 1)[1]):
        return False
    grants = entitlements.get(USB_ENTITLEMENT, [])
    return isinstance(grants, list) and any(
        isinstance(grant, dict)
        and (
            type(grant.get("idVendor")) is int
            and grant["idVendor"] == 0x1397
            or grant.get("idVendor") == "*"
            and entitlements.get("get-task-allow") is True
        )
        and ("idProduct" not in grant or type(grant["idProduct"]) is int and grant["idProduct"] == 0x00BC)
        for grant in grants
    )


def command(argv):
    return subprocess.run(argv, capture_output=True, timeout=120)


def preflight():
    identities = command(["security", "find-identity", "-v", "-p", "codesigning"])
    text = identities.stdout.decode(errors="replace")
    roots = [
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
        Path.home() / "Library/MobileDevice/Provisioning Profiles",
    ]
    decoded, failures, candidates, driver_profiles = 0, 0, 0, 0
    for path in {p for root in roots for p in root.glob("*") if p.is_file()}:
        result = command(["security", "cms", "-D", "-i", str(path)])
        if result.returncode:
            failures += 1
            continue
        try:
            profile = plistlib.loads(result.stdout)
        except plistlib.InvalidFileException:
            failures += 1
            continue
        decoded += 1
        driver_profiles += profile.get("Entitlements", {}).get("com.apple.developer.driverkit") is True
        candidates += profile_candidate(profile, datetime.now(timezone.utc))
    return {
        "readOnly": True,
        "identityQuerySucceeded": identities.returncode == 0,
        "hasDeveloperIDIdentity": "Developer ID Application:" in text,
        "hasDevelopmentIdentity": "Apple Development:" in text,
        "profilesDecoded": decoded,
        "profileDecodeFailures": failures,
        "driverProfiles": driver_profiles,
        "matchingEntitlementCandidates": candidates,
        "status": "entitlement_candidate_only" if candidates else "blocked_missing_profile_or_read_access",
        "activationAttempted": False,
        "hardwareTested": False,
    }


def observe():
    """Only inspect our extension and public BCR properties; omit other devices."""
    result = command(["systemextensionsctl", "list"])
    result.check_returncode()
    extension = next((line.strip() for line in result.stdout.decode().splitlines() if DRIVER_ID in line), None)
    registry = command(["ioreg", "-r", "-c", "IOUSBHostDevice", "-a"])
    registry.check_returncode()
    targets = []
    for node in plistlib.loads(registry.stdout):
        if node.get("idVendor") != 0x1397 or node.get("idProduct") != 0x00BC:
            continue
        override = node.get("kUSBDescriptorOverride", {})
        descriptor = override.get("descriptor", b"") if isinstance(override, dict) else b""
        targets.append(
            {
                "registryID": node.get("IORegistryEntryID"),
                "marker": node.get("BCRDescriptorProbeVersion"),
                "descriptorOverridePresent": bool(override),
                "overrideBytes": len(descriptor) if isinstance(descriptor, bytes) else 0,
            }
        )
    return {"readOnly": True, "extension": extension, "targets": targets, "hardwareVerified": False}


def generated_sources_valid(header, implementation):
    # IIG can print an error, leave empty outputs, and still return zero.
    return CLASS in header.read_text() and CLASS in implementation.read_text()


def build(report_path, output):
    output = output.resolve()
    if not output.is_relative_to(ROOT / "build"):
        raise ValueError("Generated experiment must stay under ignored build/")
    output.mkdir(parents=True, exist_ok=True)
    raw = configuration_from_report(json.loads(report_path.read_text()))
    patched, changed = patch_configuration(raw)
    sdk_result = command(["xcrun", "--sdk", "driverkit", "--show-sdk-path"])
    sdk_result.check_returncode()
    sdk = sdk_result.stdout.decode().strip()
    header, implementation = output / (CLASS + ".h"), output / (CLASS + ".cpp")

    def checked(argv):
        result = command(argv)
        (output / "last-build.stdout.txt").write_bytes(result.stdout)
        (output / "last-build.stderr.txt").write_bytes(result.stderr)
        result.check_returncode()
        if b"error:" in result.stderr.lower() or b"warning:" in result.stderr.lower():
            raise RuntimeError("Compiler diagnostic; see private build logs")

    checked(
        [
            "xcrun",
            "--sdk",
            "driverkit",
            "iig",
            "--def",
            str(ROOT / "experiments/DriverKitProbe" / (CLASS + ".iig")),
            "--header",
            str(header),
            "--impl",
            str(implementation),
            "--deployment-target",
            "23.0",
            "--",
            "-isysroot",
            sdk,
            "-x",
            "c++",
            "-std=c++20",
            "-D__IIG=1",
        ]
    )
    if not generated_sources_valid(header, implementation):
        raise RuntimeError("IIG did not generate the expected nonempty class")
    slices = []
    for arch in ("arm64", "x86_64"):
        binary = output / (CLASS + "-" + arch)
        checked(
            [
                "xcrun",
                "--sdk",
                "driverkit",
                "clang++",
                "-target",
                arch + "-apple-driverkit23.0",
                "-isysroot",
                sdk,
                "-std=c++20",
                "-fno-exceptions",
                "-fno-rtti",
                "-Wall",
                "-Wextra",
                "-Werror",
                str(implementation),
                "-framework",
                "DriverKit",
                "-o",
                str(binary),
            ]
        )
        slices.append(str(binary))
    combined = output / CLASS
    checked(["lipo", "-create", *slices, "-output", str(combined)])
    for variant in ("control", "override"):
        bundle = output / variant / (DRIVER_ID + ".dext")
        bundle.mkdir(parents=True, exist_ok=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps(info_plist(variant, patched)))
        (bundle / CLASS).write_bytes(combined.read_bytes())
        (bundle / CLASS).chmod(0o755)
    entitlements = {"com.apple.developer.driverkit": True, USB_ENTITLEMENT: [{"idVendor": 0x1397, "idProduct": 0x00BC}]}
    (output / "Driver.entitlements.plist").write_bytes(plistlib.dumps(entitlements))
    manifest = {
        "status": "compiled_only_not_activated",
        "driverBundleIdentifier": DRIVER_ID,
        "architectures": ["arm64", "x86_64"],
        "originalSHA256": hashlib.sha256(raw).hexdigest(),
        "patchedSHA256": hashlib.sha256(patched).hexdigest(),
        "changedOffset": changed,
        "originalByte": 4,
        "patchedByte": 8,
        "deploymentSignatureApplied": False,
        "hardwareTested": False,
        "activationAttempted": False,
    }
    write_json(output / "experiment.json", manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["preflight", "build", "observe"])
    parser.add_argument("--usb-report", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "build/driverkit-probe")
    args = parser.parse_args()
    if args.mode == "build" and not args.usb_report:
        parser.error("build requires an explicit cached USB report")
    if args.mode == "preflight":
        result = preflight()
    elif args.mode == "observe":
        result = observe()
    else:
        result = build(args.usb_report, args.output)
    print(json.dumps(result, indent=2))
    if args.mode == "preflight" and result["matchingEntitlementCandidates"] == 0:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
