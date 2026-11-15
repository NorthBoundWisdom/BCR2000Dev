#!/usr/bin/env python3
"""Real provider/fake-device candidate checks. No real MIDI, installation, or implicit application.

The test-only device double exists only in Debug builds: pass a Debug `--binary`.
"""

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
import threading

ROOT = Path(__file__).resolve().parents[1]

# Every check below is an assert; refuse to run where they would be stripped.
if not __debug__:
    raise SystemExit("Run without -O: these checks rely on assert")


def run(binary, profile_tool, source_map, request, output, sdk, diagnostics=False):
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
    # Fails closed for pulse/unknown buttons or roles absent from this map; show the tool's code.
    assert staged.returncode == 0, "Candidate staging refused: " + (staged.stdout.strip() or "no report")
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
    # The source map may or may not already be ready; only the candidate must be (checked below).
    assert original.returncode in (0, 3) and json.loads(original.stdout)["ready"] is (original.returncode == 0)
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
                    if diagnostics and policy == "write" and permission:
                        from surface_control_diagnostics import DEFAULT_LIMITS, ReadOnlyClient, capture, encoded, verify

                        observed_tools = []
                        snapshot_seen = threading.Event()

                        class ObservedReadOnlyClient(ReadOnlyClient):
                            def call(self, name, arguments=None):
                                observed_tools.append(name)
                                result = super().call(name, arguments)
                                if name == "surface_control_snapshot":
                                    snapshot_seen.set()
                                return result

                        diagnostic_client = ObservedReadOnlyClient(
                            ready["url"], token, "candidate-process", accepted_sources=("hardware",)
                        )
                        errors = []

                        def operate_fake_buttons():
                            try:
                                assert snapshot_seen.wait(5)
                                inject(rows)
                            except Exception as error:
                                errors.append(type(error).__name__)

                        operator = threading.Thread(target=operate_fake_buttons)
                        operator.start()
                        limits = dict(
                            DEFAULT_LIMITS,
                            duration_s=1.0,
                            max_polls=10,
                            max_events=64,
                            max_bytes=1048576,
                            interval_s=0.05,
                        )
                        document = capture(
                            diagnostic_client,
                            "bcr2000.hardware",
                            "1.4",
                            required_controls=[roles["enable"], roles["stop"]],
                            limits=limits,
                        )
                        operator.join(timeout=5)
                        assert not operator.is_alive() and not errors
                        diagnostic_report = verify(document)
                        assert document["end"]["event_count"] == 4
                        assert (
                            diagnostic_report["exit_code"] == 0 and diagnostic_report["physical_qualification"] is False
                        )
                        assert set(observed_tools) <= {
                            "surface_control_discover",
                            "surface_control_snapshot",
                            "surface_control_events",
                        }
                        raw_capture = encoded(document)
                        assert token.encode() not in raw_capture and ready["url"].encode() not in raw_capture
                        (directory / "diagnostic-capture.json").write_bytes(raw_capture)
                        (directory / "diagnostic-report.json").write_text(
                            json.dumps(diagnostic_report, indent=2) + "\n"
                        )
                        # Exercise the capture CLI without writing the credential to any file.
                        read_fd, write_fd = os.pipe()
                        os.write(write_fd, token.encode())
                        os.close(write_fd)
                        try:
                            cli = subprocess.run(
                                [
                                    sys.executable,
                                    "-B",
                                    "-m",
                                    "surface_control_diagnostics",
                                    "capture",
                                    "--url",
                                    ready["url"],
                                    "--token-file",
                                    "/dev/fd/" + str(read_fd),
                                    "--instance-id",
                                    "candidate-process",
                                    "--profile-id",
                                    "bcr2000.hardware",
                                    "--profile-version",
                                    "1.4",
                                    "--accept-hardware",
                                    "--require-control",
                                    roles["enable"],
                                    "--require-control",
                                    roles["stop"],
                                    "--max-polls",
                                    "1",
                                    "--output",
                                    str(directory / "diagnostic-cli-capture.json"),
                                ],
                                env=dict(os.environ, PYTHONPATH=str(sdk)),
                                pass_fds=(read_fd,),
                                capture_output=True,
                                text=True,
                            )
                        finally:
                            os.close(read_fd)
                        assert cli.returncode == 0, "Read-only diagnostic CLI failed"
                        offline_cli = subprocess.run(
                            [
                                sys.executable,
                                "-B",
                                "-m",
                                "surface_control_diagnostics",
                                "verify",
                                "--capture",
                                str(directory / "diagnostic-cli-capture.json"),
                            ],
                            env=dict(os.environ, PYTHONPATH=str(sdk)),
                            capture_output=True,
                            text=True,
                        )
                        assert (
                            offline_cli.returncode == 0
                            and json.loads(offline_cli.stdout)["physical_qualification"] is False
                        )
                        # The delivered field probe is exercised as a real subprocess with private stdin.
                        for action in ("edges", "raw-edges"):
                            probe = subprocess.Popen(
                                [
                                    sys.executable,
                                    str(ROOT / "Support/NativeDiagnostics/f_candidate_probe.py"),
                                    "--sdk",
                                    str(sdk),
                                    "--provider-sdk",
                                    str(ROOT / "Clients/Python"),
                                    "--url",
                                    ready["url"],
                                    "--instance",
                                    "candidate-process",
                                    "--mapping-revision",
                                    client.expected["mapping_revision"],
                                    "--action",
                                    action,
                                    "--control",
                                    roles["enable"],
                                ],
                                stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                text=True,
                            )
                            try:
                                probe.stdin.write(token)
                                probe.stdin.close()
                                assert json.loads(probe.stdout.readline())["event"] == (
                                    "awaiting_new_edges" if action == "edges" else "awaiting_new_raw_edges"
                                )
                                inject(rows)
                                probe_result = json.loads(probe.stdout.readline())
                                assert probe.wait(timeout=5) == 0
                                assert (
                                    probe_result.get("press_release_edges") == 2
                                    if action == "edges"
                                    else probe_result.get("raw_press_release") == [127, 0]
                                )
                                assert probe_result["physical_qualification"] is False
                                probe_error = probe.stderr.read()
                                assert token not in json.dumps(probe_result) + probe_error
                            finally:
                                if probe.poll() is None:
                                    probe.kill()
                                    probe.wait()
                                probe.stdout.close()
                                probe.stderr.close()
                        for value in ("on", "off"):
                            displayed = subprocess.run(
                                [
                                    sys.executable,
                                    str(ROOT / "Support/NativeDiagnostics/f_candidate_probe.py"),
                                    "--sdk",
                                    str(sdk),
                                    "--provider-sdk",
                                    str(ROOT / "Clients/Python"),
                                    "--url",
                                    ready["url"],
                                    "--instance",
                                    "candidate-process",
                                    "--mapping-revision",
                                    client.expected["mapping_revision"],
                                    "--action",
                                    "display",
                                    "--control",
                                    roles["enable"],
                                    "--value",
                                    value,
                                    "--confirm-attended-display",
                                ],
                                input=token,
                                capture_output=True,
                                text=True,
                                timeout=5,
                            )
                            assert displayed.returncode == 0 and json.loads(displayed.stdout)["transport_accepted"]
                            assert token not in displayed.stdout + displayed.stderr
                        cases.append(
                            {
                                "name": "F-field-probe-edges-and-two-display-commands",
                                "passed": True,
                                "captured_edges": 2,
                                "display_requests": 2,
                                "physical_qualification": False,
                            }
                        )
                        cases.append(
                            {
                                "name": "read-only-diagnostic-api-cli-and-offline-verify",
                                "passed": True,
                                "diagnostic_status": diagnostic_report["diagnostic_status"],
                                "captured_new_button_edges": document["end"]["event_count"],
                                "physical_qualification": False,
                                "tools": sorted(set(observed_tools)),
                                "credential_storage": "anonymous pipe only",
                            }
                        )
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
    parser.add_argument("--diagnostics", action="store_true")
    args = parser.parse_args()
    run(
        *(getattr(args, key).resolve() for key in ("binary", "profile_tool", "source_map", "request", "output", "sdk")),
        diagnostics=args.diagnostics,
    )


if __name__ == "__main__":
    main()
