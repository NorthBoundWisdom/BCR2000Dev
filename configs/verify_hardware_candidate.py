#!/usr/bin/env python3
"""Real provider/fake-device candidate checks. No real MIDI, installation, or implicit application."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def run(binary, profile_tool, source_map, request, output, sdk):
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(sdk))
    from surface_control import Client, SurfaceError

    output.mkdir(parents=True, exist_ok=False)
    before = source_map.read_bytes()
    candidate = output / "candidate"
    staged = subprocess.run(
        [str(profile_tool), "--stage-hardware-candidate", str(source_map), str(request), str(candidate)],
        capture_output=True,
        text=True,
    )
    assert staged.returncode == 0, "Candidate staging failed"
    manifest = json.loads(staged.stdout)
    assert manifest["ready"] is False and manifest["software_ready"] is True and manifest["hardware_qualified"] is False
    assert manifest["source_map_sha256"] == hashlib.sha256(before).hexdigest()
    verified = subprocess.run(
        [str(profile_tool), "--verify-hardware-candidate", str(candidate)], capture_output=True, text=True
    )
    assert verified.returncode == 0 and json.loads(verified.stdout)["ready"] is False
    original = subprocess.run(
        [
            str(profile_tool),
            "--check-hardware-roles",
            str(source_map),
            str(request),
            "--hardware-output",
            "write",
            "--allow-surface-feedback",
        ],
        capture_output=True,
        text=True,
    )
    assert original.returncode == 3 and json.loads(original.stdout)["ready"] is False
    offline = subprocess.run(
        [
            str(profile_tool),
            "--check-hardware-roles",
            str(candidate / "candidate-hardware-map.json"),
            str(request),
            "--configuration",
            str(candidate / "candidate-configuration.json"),
            "--hardware-output",
            "write",
            "--allow-surface-feedback",
        ],
        capture_output=True,
        text=True,
    )
    assert offline.returncode == 0 and json.loads(offline.stdout)["hardware_qualified"] is False
    roles = json.loads(request.read_text())["roles"]
    entries = json.loads((candidate / "candidate-hardware-map.json").read_text())["entries"]
    by_id = {"{section}.{row}.{index}".format(**entry["control"]): entry for entry in entries}
    cases = []

    def rejected(action, code):
        try:
            action()
        except SurfaceError as error:
            assert error.code == code, error.code
        else:
            raise AssertionError("Expected rejection " + code)

    for policy in ("observe", "write"):
        for permission in (False, True):
            name = policy + ("-display" if permission else "-no-display")
            directory = output / name
            directory.mkdir()
            script, report = directory / "commands.json", directory / "device.json"
            script.write_text("[]")
            token = secrets.token_hex(32)
            environment = dict(
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
                "--hardware-profile",
                "--hardware-map",
                str(candidate / "candidate-hardware-map.json"),
                "--configuration",
                str(candidate / "candidate-configuration.json"),
                "--hardware-output",
                policy,
                "--surface-instance-id",
                "candidate-process",
                "--port",
                "0",
            ]
            if permission:
                command.append("--allow-surface-feedback")
            with (directory / "stderr.log").open("w") as stderr:
                host = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=stderr, env=environment, text=True)
                try:
                    selector = selectors.DefaultSelector()
                    selector.register(host.stdout, selectors.EVENT_READ)
                    assert selector.select(10), "Test provider did not start"
                    ready = json.loads(host.stdout.readline())
                    assert ready["test_only_hardware_double"] is True
                    client = Client(ready["url"], token, "candidate-process", accepted_sources=("hardware",))
                    client.discover(versions=("1.4",))
                    assert client.snapshot()["inputs"] == {}

                    def inject(rows):
                        prior = json.loads(script.read_text())
                        next_path = script.with_suffix(".next")
                        next_path.write_text(json.dumps(prior + rows))
                        next_path.replace(script)
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            if report.exists() and json.loads(report.read_text())["consumed"] == len(prior) + len(rows):
                                return
                            time.sleep(0.02)
                        raise AssertionError("Fake candidate input did not advance")

                    rows = []
                    for role in ("enable", "stop"):
                        entry = by_id[roles[role]]
                        # Test transport currently implements the recorded MIDI channel-1 CC form.
                        assert entry["midi"]["kind"] == "controlChange" and entry["midi"]["channel"] == 0
                        rows += [
                            {"operation": "input", "cc": entry["midi"]["number"], "value": value} for value in (127, 0)
                        ]
                    inject(rows)
                    page = client.call(
                        "surface_control_events",
                        {
                            "instance_id": client.instance_id,
                            "epoch": client.expected["epoch"],
                            "after_sequence": "0",
                            "limit": 1024,
                        },
                    )
                    events = page["events"]
                    assert len(events) == 4 and all(
                        event["disposition"] == "accepted" and event["origin"] == event["source"] == "hardware"
                        for event in events
                    )
                    assert [event["value"] for event in events] == [True, False, True, False]
                    snapshot = client.snapshot()
                    assert snapshot["inputs"][roles["enable"]] is False and snapshot["inputs"][roles["stop"]] is False
                    sent_before = len(json.loads(report.read_text())["sent"])
                    feedback = [(roles["enable"], "indicator", "on"), (roles["linear"], "value", 64)]
                    for control, kind, value in feedback:
                        if policy == "write" and permission:
                            result = client.feedback(control, kind, value)
                            assert result["disposition"] == "accepted"
                        else:
                            rejected(
                                lambda control=control, kind=kind, value=value: client.feedback(control, kind, value),
                                "permission_denied",
                            )
                    # Wait only for the fake report observation; never retry a command.
                    deadline = time.monotonic() + 2
                    expected = sent_before + (2 if policy == "write" and permission else 0)
                    while time.monotonic() < deadline and len(json.loads(report.read_text())["sent"]) != expected:
                        time.sleep(0.02)
                    assert len(json.loads(report.read_text())["sent"]) == expected
                    assert client.snapshot()["latest_input_sequence"] == "4", "Display became operator input"
                    cases.append(
                        {
                            "name": name,
                            "accepted_button_edges": 4,
                            "requested_display_sends": expected - sent_before,
                            "passed": True,
                            "real_device_sends": 0,
                        }
                    )
                finally:
                    host.terminate()
                    try:
                        host.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        host.kill()
                        host.wait()
                    host.stdout.close()
    assert source_map.read_bytes() == before
    result = {
        "passed": True,
        "scope": "test-only device, real provider process",
        "ready": False,
        "software_ready": True,
        "hardware_qualified": False,
        "cases": cases,
        "source_map_unchanged": True,
        "real_device_sends": 0,
        "missing_evidence": manifest["missing_evidence"],
    }
    (output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--profile-tool", type=Path, required=True)
    parser.add_argument("--source-map", type=Path, required=True)
    parser.add_argument("--request", type=Path, default=ROOT / "examples/hardware/role-readiness-request.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, default=ROOT / "build/seed/SurfacePlugins/clients/python")
    args = parser.parse_args()
    run(*(getattr(args, key).resolve() for key in ("binary", "profile_tool", "source_map", "request", "output", "sdk")))


if __name__ == "__main__":
    main()
