#!/usr/bin/env python3
"""Build a private universal macOS diagnostic bundle; no release/tag/deployment."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

from macos_test_session import load_target_profile

REPO = Path(__file__).resolve().parents[1]
FILES = ["midi_feedback_probe.py", "bcr_protocol.py", "bcr_roundtrip.py", "diagnostic_io.py",
         "macos_bcr_roundtrip.py", "macos_bcr_selftest.py", "macos_test_session.py", "macos_gui_session.py",
         "macos_usb_descriptor.swift", "windows_usb_descriptor.py", "Run-Mac-Diagnostics.command"]


def sanitize_baseline(value):
    allowed = {"vendor", "product", "configuration", "currentConfiguration", "numConfigurations", "configurationBytes",
               "speedCode", "usbVersionBcd", "descriptors"}
    if not isinstance(value, dict) or not isinstance(value.get("targets"), list) or len(value["targets"]) != 1:
        raise ValueError("Need exactly one Windows USB reference target")
    target = value["targets"][0]
    if not isinstance(target, dict) or target.get("vendor") != "0x1397" or target.get("product") != "0xbc":
        raise ValueError("Reference is not the BCR2000 USB model")
    for key in ("configuration", "currentConfiguration", "numConfigurations", "configurationBytes", "speedCode"):
        if key in target and (type(target[key]) is not int or not 0 <= target[key] <= 8192):
            raise ValueError("Invalid numeric USB reference field")
    if "usbVersionBcd" in target:
        value = target["usbVersionBcd"]
        if not isinstance(value, str) or not value.startswith("0x") or len(value) > 6 or not 0 <= int(value, 16) <= 65535:
            raise ValueError("Invalid USB version reference")
    descriptors = target.get("descriptors")
    if not isinstance(descriptors, list):
        raise ValueError("Reference descriptors must be a list")
    descriptor_keys = {"interface", "alternate", "endpoints", "class", "subclass", "protocol",
                       "endpointAddress", "attributes", "maxPacket", "interval", "classInterface", "classEndpoint"}
    for item in descriptors:
        if not isinstance(item, dict) or set(item) - descriptor_keys:
            raise ValueError("Unexpected descriptor metadata; refusing to bundle it")
        for key, value in item.items():
            if key in ("classInterface", "classEndpoint"):
                if not isinstance(value, list) or any(type(v) is not int or not 0 <= v <= 255 for v in value):
                    raise ValueError("Invalid class descriptor bytes")
            elif key == "endpointAddress":
                if not isinstance(value, str) or not 0 <= int(value, 16) <= 255:
                    raise ValueError("Invalid endpoint address")
            elif type(value) is not int or not 0 <= value <= (65535 if key == "maxPacket" else 255):
                raise ValueError("Invalid numeric descriptor field")
    return {"targets": [{key: target[key] for key in allowed if key in target}]}


def verify_architectures(output):
    architectures = output.split()
    if len(architectures) != 2 or set(architectures) != {"arm64", "x86_64"}:
        raise RuntimeError("Universal helper must contain exactly arm64 and x86_64")


def build(output, baseline=None, target_profile=None, allow_dirty=False):
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=REPO, text=True).strip())
    if dirty and not allow_dirty:
        raise RuntimeError("Commit verified sources first; use --allow-dirty only for an explicitly marked development bundle")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / ("BCR2000-Mac-Diagnostics-" + revision[:12] + ("-dirty" if dirty else "") + ".zip")
    with tempfile.TemporaryDirectory(prefix="bcr-package-") as temporary:
        root = Path(temporary) / "BCR2000-Mac-Diagnostics"
        root.mkdir(mode=0o700)
        for name in FILES:
            shutil.copy2(REPO / "tools" / name, root / name)
        shutil.copy2(REPO / "docs/MAC_REMOTE_TEST_PLAN.md", root / "README.md")
        native = root / "bin"
        native.mkdir()
        objects = []
        for architecture in ["arm64", "x86_64"]:
            binary = Path(temporary) / ("usb-" + architecture)
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-O",
                            "-target", architecture + "-apple-macos14.0", str(root / "macos_usb_descriptor.swift"), "-o", str(binary)], check=True)
            objects.append(str(binary))
        helper = native / "macos-usb-descriptor"
        subprocess.run(["xcrun", "lipo", "-create", *objects, "-output", str(helper)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(helper)], check=True, capture_output=True)
        subprocess.run(["codesign", "--verify", "--strict", str(helper)], check=True, capture_output=True)
        verify_architectures(subprocess.check_output(["xcrun", "lipo", str(helper), "-archs"], text=True))
        if baseline:
            directory = root / "baselines"; directory.mkdir()
            (directory / "windows-usb.json").write_text(json.dumps(sanitize_baseline(json.loads(Path(baseline).read_text())), indent=2))
        if target_profile:
            profile = load_target_profile(target_profile)
            directory = root / "private"; directory.mkdir(mode=0o700)
            path = directory / "target.local.json"
            path.write_text(json.dumps(profile, indent=2)); os.chmod(path, 0o600)
        manifest = {"schemaVersion": 1, "revision": revision, "dirty": dirty,
                    "builtAtUTC": datetime.now(timezone.utc).isoformat(), "minimumMacOS": "14.0",
                    "architectures": ["arm64", "x86_64"], "containsPrivateTarget": bool(target_profile),
                    "files": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in sorted(root.rglob("*")) if path.is_file()}}
        (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
        temporary_zip = archive.with_suffix(".zip.tmp")
        with zipfile.ZipFile(temporary_zip, "w", zipfile.ZIP_DEFLATED) as zipped:
            for path in sorted(root.rglob("*")):
                zipped.write(path, arcname=str(path.relative_to(root.parent)))
            if zipped.testzip() is not None:
                raise RuntimeError("Archive integrity check failed")
        os.replace(temporary_zip, archive)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(checksum + "  " + archive.name + "\n")
    print(json.dumps({"archive": str(archive), "sha256": checksum, "revision": revision, "dirty": dirty}))
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=str(REPO / "build/macos-diagnostics"))
    parser.add_argument("--baseline")
    parser.add_argument("--target-profile")
    parser.add_argument("--allow-dirty", action="store_true")
    args = parser.parse_args()
    build(args.output, args.baseline, args.target_profile, args.allow_dirty)


if __name__ == "__main__":
    main()
