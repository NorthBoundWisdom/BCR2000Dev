#!/usr/bin/env python3
"""Real-process, no-device coverage of headless tool catalogue option gates."""

from __future__ import annotations
import argparse
import json
import hashlib
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Clients/Python"))
sys.path.insert(0, str(ROOT / "Support/NativeDiagnostics"))
from bcr_provider import Client  # noqa: E402
from verify_provider_catalogue import verify  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    record = json.loads((ROOT / "docs/provider-tool-compatibility.json").read_text())
    described = json.loads(subprocess.check_output([str(binary), "--describe-surface"]))["discovery"]
    discovery_hash = hashlib.sha256(
        json.dumps(described, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    assert discovery_hash == "cdc82e8afd9dbbc4a795f2f191c3c59fa7bdd8db3f8304ba64ee58879b5c8838", (
        "Simulation discovery changed from frozen E-pre delivery"
    )
    cases = [{"name": "simulation_discovery_fixed_encoding_matches_E_pre", "passed": True, "sha256": discovery_hash}]
    options = [
        ("default", [], {}),
        ("robot", ["--robot-sim"], {"robot": True}),
        ("chassis", ["--chassis-sim"], {"chassis": True}),
        ("both", ["--robot-sim", "--chassis-sim"], {"robot": True, "chassis": True}),
        ("no-console", ["--no-console"], {"console": False}),
        ("simulation-profile", ["--simulation-profile"], {"surface": True}),
        (
            "simulation-configuration",
            ["--simulation-configuration", str(ROOT / "examples/simulation/chassis-controls.json")],
            {"surface": True},
        ),
    ]
    for flag in ("--surface-instance-id", "--allow-surface-input", "--allow-surface-feedback", "--allow-surface-reset"):
        options.append((flag[2:], [flag, "catalogue"] if flag.endswith("instance-id") else [flag], {"surface": True}))
    options.append(("robot-surface", ["--robot-sim", "--simulation-profile"], {"robot": True, "surface": True}))
    with tempfile.TemporaryDirectory(prefix="bcr-f-catalogue-") as temporary:
        tmp = Path(temporary)
        mapping = tmp / "TEST-ONLY-map.json"
        mapping.write_text(
            json.dumps(
                {
                    "version": 7,
                    "entries": [
                        {
                            "control": {"section": "pushEncoder", "row": 1, "index": 1},
                            "midi": {"kind": "controlChange", "channel": 0, "number": 8},
                        }
                    ],
                }
            )
        )
        script, report = tmp / "TEST-ONLY-commands.json", tmp / "TEST-ONLY-device.json"
        script.write_text("[]")
        options.append(
            (
                "hardware-profile",
                ["--source", "hardware", "--hardware-profile", "--hardware-map", str(mapping)],
                {"surface": True},
            )
        )
        for name, flags, expected in options:
            token = secrets.token_hex(32)
            env = {**os.environ, "BCR_PROVIDER_TOKEN": token}
            if name == "hardware-profile":
                env.update(
                    BCR_PROVIDER_TEST_HARDWARE="1",
                    BCR_PROVIDER_TEST_HARDWARE_SCRIPT=str(script),
                    BCR_PROVIDER_TEST_HARDWARE_REPORT=str(report),
                )
            with (args.output / (name + ".stderr.log")).open("w") as stderr:
                process = subprocess.Popen(
                    [str(binary), "--port", "0", *flags],
                    cwd=temporary,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=stderr,
                    text=True,
                )
                try:
                    selector = selectors.DefaultSelector()
                    selector.register(process.stdout, selectors.EVENT_READ)
                    assert selector.select(10), name + " did not become ready"
                    ready = json.loads(process.stdout.readline())
                    client = Client(ready["url"], token, expected_provider_id=ready["provider_id"])
                    tools = client.tools()
                    result = verify(tools, record, **expected)
                    cli_flags = [
                        "--" + key if key != "console" else "--no-console"
                        for key, value in expected.items()
                        if value or key == "console"
                    ]
                    checked = subprocess.run(
                        [
                            sys.executable,
                            str(ROOT / "Support/NativeDiagnostics/verify_provider_catalogue.py"),
                            "--record",
                            str(ROOT / "docs/provider-tool-compatibility.json"),
                            "--url",
                            ready["url"],
                            "--provider-id",
                            ready["provider_id"],
                            "--token-stdin",
                            *cli_flags,
                        ],
                        input=token,
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    assert token not in checked.stdout + checked.stderr, "Credential in checker output"
                    assert checked.returncode == 0, "Read-only catalogue CLI failed: " + checked.stdout
                    assert json.loads(checked.stdout)["actual_count"] == len(tools)
                    cases.append({"name": name, "flags": [f for f in flags if not f.startswith(temporary)], **result})
                    print("PASS", name, result["actual_count"], flush=True)
                finally:
                    process.terminate()
                    process.wait(timeout=5)
                    process.stdout.close()
    summary = {
        "passed_count": len(cases),
        "failed_count": 0,
        "skipped_count": 0,
        "cases": cases,
        "device_scope": "Mock and explicitly marked Debug-only test double; no CoreMIDI",
    }
    (args.output / "report.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "cases"}))


if __name__ == "__main__":
    main()
