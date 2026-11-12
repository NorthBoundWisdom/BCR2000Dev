#!/usr/bin/env python3
"""Minimal generic simulation consumer using only a pinned public delivery, no Pipe.

The Surface control SDK 1.3.0 inside the delivery is a byte-identical copy of the locked
SurfacePlugins source; this example verifies the manifest pin and every file hash first.
"""

import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import sys

CONTRACT, SDK = "1.3", "1.3.0"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def delivery(root, expected):
    manifest_path = root / "manifest.json"
    require(digest(manifest_path) == expected, "artifact manifest pin mismatch")
    manifest = json.loads(manifest_path.read_text())
    require(
        manifest.get("surface_control_contract") == CONTRACT and manifest.get("surface_control_sdk") == SDK,
        "unsupported optional Surface delivery",
    )
    for name, wanted in manifest["files_sha256"].items():
        path = root / name
        require(
            not Path(name).is_absolute()
            and ".." not in Path(name).parts
            and path.is_file()
            and not path.is_symlink()
            and path.resolve().is_relative_to(root)
            and digest(path) == wanted,
            "artifact file hash/path mismatch",
        )
    sdk = root / f"surface-control-sdk-{SDK}.zip"
    require(sdk.name in manifest["files_sha256"], "Surface SDK is not in manifest")
    require("surface_control" not in sys.modules, "another Surface SDK is already loaded")
    sys.path.insert(0, str(sdk))
    module = importlib.import_module("surface_control")
    require(str(module.__file__).startswith(str(sdk) + "/"), "SDK import is not from pinned artifact")
    require(module.__version__ == SDK, "unexpected Surface SDK version")
    return module, manifest


def private_token(path):
    info = path.stat()
    require(
        path.is_file() and not path.is_symlink() and info.st_uid == os.geteuid() and not info.st_mode & 0o077,
        "token must be an owned private regular file",
    )
    return path.read_text().strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--provider-id", help="Pin the startup provider_id from provider.ready (recommended)")
    parser.add_argument("--input-parameter", default="simulation.arm")
    parser.add_argument("--feedback-parameter", default="simulation.progress")
    args = parser.parse_args()
    sdk, _ = delivery(args.artifact.resolve(), args.manifest_sha256)
    pin = {"provider_id": args.provider_id, "provider_header": "BCR-Provider-Id"} if args.provider_id else {}
    client = sdk.Client(args.url, private_token(args.token_file), args.instance_id, **pin)
    discovery = client.discover(profiles=("bcr2000.mock",))
    rows = discovery["profile"]["controls"]

    def mapped(identifier):
        found = [row for row in rows if (row.get("mapping") or {}).get("id") == identifier]
        require(len(found) == 1, "one explicit mapping is required")
        return found[0]

    source, display = mapped(args.input_parameter), mapped(args.feedback_parameter)
    require(source["encoding"] == "scalar" and "value" in display["feedback_kinds"], "scalar/value capability required")
    before = client.snapshot()
    raw = source["range"]["maximum"]
    event = client.input(source["id"], source["encoding"], raw)
    observed = client.snapshot()
    value = (display.get("feedback_range") or display["range"])["maximum"]
    feedback = client.feedback(display["id"], "value", value)
    after = client.snapshot()
    require(observed["inputs"] == after["inputs"], "feedback changed an input")
    print(
        json.dumps(
            {
                "source": "simulation",
                "contract_version": discovery["contract_version"],
                "expected": client.expected,
                "before_sequence": before["latest_sequence"],
                "input": event,
                "feedback": feedback,
                "after_sequence": after["latest_sequence"],
                "passed": True,
            }
        )
    )


if __name__ == "__main__":
    main()
