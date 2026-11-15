#!/usr/bin/env python3
"""Run the real provider process against a test-only device double. Never opens CoreMIDI.

The double exists only in Debug builds: pass a Debug provider binary.
"""

from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]

# Every check below is an assert; refuse to run where they would be stripped.
if not __debug__:
    raise SystemExit("Run without -O: these checks rely on assert")


def run(binary, output, sdk):
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(sdk))
    from surface_control import Client, SurfaceError

    output.mkdir(parents=True, exist_ok=False)
    cases = []
    # Explicit test-only map, never written to user state or applied to real hardware.
    mapping = {
        "version": 7,
        "entries": [
            {
                "control": {"section": section, "row": row, "index": index},
                "midi": {"kind": "controlChange", "channel": 0, "number": cc},
                **({"pressMode": "momentary"} if section == "button" else {}),
            }
            for section, row, index, cc in [("pushEncoder", 1, 1, 8), ("pushEncoder", 2, 1, 19), ("button", 1, 1, 70)]
        ],
    }
    map_path = output / "TEST-ONLY-map.json"
    map_path.write_text(json.dumps(mapping))

    described = json.loads(
        subprocess.check_output(
            [
                str(binary),
                "--source",
                "hardware",
                "--hardware-profile",
                "--hardware-map",
                str(map_path),
                "--describe-surface",
            ]
        )
    )["discovery"]

    def error(action, code):
        try:
            action()
        except SurfaceError as failure:
            assert failure.code == code, failure.code
        else:
            raise AssertionError("Expected " + code)

    for policy in ("observe", "write"):
        for allowed in (False, True):
            name = policy + ("-allowed" if allowed else "-denied")
            directory = output / name
            directory.mkdir()
            script, report = directory / "commands.json", directory / "device.json"
            script.write_text("[]")
            token = secrets.token_hex(32)
            env = dict(
                os.environ,
                BCR_PROVIDER_TOKEN=token,
                BCR_PROVIDER_TEST_HARDWARE="1",
                BCR_PROVIDER_TEST_HARDWARE_SCRIPT=str(script),
                BCR_PROVIDER_TEST_HARDWARE_REPORT=str(report),
            )
            command = [
                str(binary),
                "--source",
                "hardware",
                "--hardware-output",
                policy,
                "--hardware-profile",
                "--hardware-map",
                str(map_path),
                "--port",
                "0",
                "--surface-instance-id",
                "e-hardware",
            ]
            if allowed:
                command.append("--allow-surface-feedback")
            with (directory / "stderr.log").open("w") as stderr:
                host = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=stderr, env=env, text=True)
                try:
                    selector = selectors.DefaultSelector()
                    selector.register(host.stdout, selectors.EVENT_READ)
                    assert selector.select(10), "Provider did not become ready"
                    ready = json.loads(host.stdout.readline())
                    assert ready["test_only_hardware_double"] is True and ready["hardware_output"] == policy
                    client = Client(ready["url"], token, "e-hardware", accepted_sources=("hardware",))
                    d = client.discover(versions=("1.4",))
                    assert (
                        d["profile"] == described["profile"]
                        and d["expected"]["mapping_revision"] == described["expected"]["mapping_revision"]
                    )
                    assert d["source"] == "hardware" and client.snapshot()["inputs"] == {}
                    legacy = Client(ready["url"], token, "e-hardware")
                    error(legacy.discover, "unsupported_contract")

                    def page(expected=None):
                        return client.call(
                            "surface_control_events",
                            {
                                "instance_id": client.instance_id,
                                "epoch": (expected or client.expected)["epoch"],
                                "after_sequence": "0",
                                "limit": 1024,
                            },
                        )

                    def inject(steps):
                        previous = json.loads(script.read_text())
                        temporary = script.with_suffix(".next")
                        temporary.write_text(json.dumps(previous + steps))
                        temporary.replace(script)
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            if report.exists() and json.loads(report.read_text())["consumed"] == len(previous) + len(
                                steps
                            ):
                                return
                            time.sleep(0.02)
                        raise AssertionError("Test-only device script did not advance")

                    inject(
                        [
                            {"operation": "input", "cc": 8, "value": 45},
                            {"operation": "input", "cc": 19, "value": 61},
                            {"operation": "input", "cc": 70, "value": 127},
                            {"operation": "input", "cc": 70, "value": 0},
                        ]
                    )
                    entries = page()["events"]
                    assert len(entries) == 4 and all(e["source"] == e["origin"] == "hardware" for e in entries)
                    assert [e["sequence"] for e in entries] == ["1", "2", "3", "4"]
                    client.snapshot()
                    before = len(json.loads(report.read_text())["sent"])
                    feedback = lambda: client.feedback("pushEncoder.1.1", "value", 64)
                    if policy == "write" and allowed:
                        feedback()
                        inject([{"operation": "input", "cc": 8, "value": 64}])
                        assert client.snapshot()["latest_input_sequence"] == "4", "Echo became input"
                        assert len(json.loads(report.read_text())["sent"]) - before == 1
                    else:
                        error(feedback, "permission_denied")
                        assert len(json.loads(report.read_text())["sent"]) == before
                    for tool, args, code in [
                        (
                            "surface_control_input",
                            {
                                "expected": client.expected,
                                "expected_sequence": client.latest_sequence,
                                "control_id": "pushEncoder.1.1",
                                "encoding": "scalar",
                                "value": 10,
                            },
                            "permission_denied",
                        ),
                        (
                            "surface_control_renew",
                            {"expected": client.expected, "control_id": "button.1.1", "hold_s": 1},
                            "unsupported_hold",
                        ),
                        (
                            "surface_control_reset",
                            {"expected": client.expected, "expected_sequence": client.latest_sequence},
                            "unsupported_tool",
                        ),
                    ]:
                        error(lambda tool=tool, args=args: client.call(tool, args), code)
                    old = dict(client.expected)
                    inject([{"operation": "disconnect"}])
                    error(lambda: page(old), "stale_epoch")
                    client = Client(ready["url"], token, "e-hardware", accepted_sources=("hardware",))
                    client.discover(versions=("1.4",))
                    s = client.snapshot()
                    assert s["link"]["state"] == "disconnected" and s["inputs"] == {}
                    inject([{"operation": "input", "cc": 8, "value": 99}, {"operation": "reconnect"}])
                    client = Client(ready["url"], token, "e-hardware", accepted_sources=("hardware",))
                    client.discover(versions=("1.4",))
                    s = client.snapshot()
                    assert s["link"]["state"] == "connected" and s["inputs"] == {} and s["latest_sequence"] == "0"
                    cases.append({"name": name, "passed": True, "device": "test-only", "real_device_sends": 0})
                finally:
                    host.terminate()
                    try:
                        host.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        host.kill()
                        host.wait()
                    host.stdout.close()
    result = {
        "passed": True,
        "scope": "real-process-loopback-with-test-only-device",
        "hardware_verified": False,
        "cases": cases,
        "passed_count": len(cases),
        "failed_count": 0,
        "skipped_count": 0,
    }
    (output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, default=ROOT / "build/seed/SurfacePlugins/clients/python")
    args = parser.parse_args()
    run(args.binary.resolve(), args.output.resolve(), args.sdk.resolve())


if __name__ == "__main__":
    main()
