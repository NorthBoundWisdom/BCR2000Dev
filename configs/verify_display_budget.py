#!/usr/bin/env python3
"""Real-process opt-in display quota checks; only simulation and Debug fake hardware."""

import argparse
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "build/seed/SurfacePlugins/clients/python"))
from surface_control import Client, SurfaceError  # noqa: E402


def denied(action, code):
    try:
        action()
    except SurfaceError as failure:
        assert failure.code == code, (failure.code, code)
    else:
        raise AssertionError("Expected exact rejection")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve()
    env = {key: value for key, value in os.environ.items() if key != "BCR_PROVIDER_TOKEN"}
    cases = []
    for label, flags in (
        ("zero", ["--display-write-limit", "0"]),
        ("upper", ["--display-write-limit", "1001"]),
        ("fraction", ["--display-write-limit", "1.5"]),
        ("repeated", ["--display-write-limit", "2", "--display-write-limit", "2"]),
        ("missing-private-role-mode", ["--display-write-limit", "2"]),
    ):
        flags += [] if label == "missing-private-role-mode" else ["--surface-client-tokens-stdin"]
        result = subprocess.run([str(binary), *flags], input="", capture_output=True, text=True, env=env, timeout=5)
        assert result.returncode == 2
        cases.append({"name": label + "_startup_refused", "passed": True})
    reference = subprocess.check_output([str(binary), "--describe-surface"], env=env)
    for maximum in (1, 1000):
        actual = subprocess.check_output(
            [str(binary), "--describe-surface", "--display-write-limit", str(maximum), "--surface-client-tokens-stdin"],
            env=env,
        )
        assert reference == actual
        cases.append({"name": f"boundary_{maximum}_accepted_and_discovery_unchanged", "passed": True})
    for source in ("simulation", "hardware"):
        directory = args.output / source
        directory.mkdir()
        credentials = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
        flags = [
            "--port",
            "0",
            "--surface-instance-id",
            "quota",
            "--surface-client-tokens-stdin",
            "--display-write-limit",
            "2",
            "--write-limit",
            "1",
            "--allow-surface-feedback",
        ]
        host_env = dict(env)
        if source == "simulation":
            flags += ["--simulation-profile"]
        else:
            mapping = directory / "TEST-ONLY-map.json"
            mapping.write_text(
                json.dumps(
                    {
                        "version": 7,
                        "entries": [
                            {
                                "control": {"section": "pushEncoder", "row": 1, "index": 1},
                                "midi": {"kind": "controlChange", "channel": 0, "number": 1},
                                "ringMode": "12dot",
                            }
                        ],
                    }
                )
            )
            commands = directory / "commands.json"
            commands.write_text("[]")
            host_env.update(
                BCR_PROVIDER_TEST_HARDWARE="1",
                BCR_PROVIDER_TEST_HARDWARE_SCRIPT=str(commands),
                BCR_PROVIDER_TEST_HARDWARE_REPORT=str(directory / "device.json"),
            )
            flags += [
                "--source",
                "hardware",
                "--hardware-profile",
                "--hardware-map",
                str(mapping),
                "--hardware-output",
                "write",
            ]
        with (directory / "stderr.log").open("w") as stderr:
            process = subprocess.Popen(
                [str(binary), *flags],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr,
                env=host_env,
                text=True,
            )
            try:
                process.stdin.write(json.dumps(credentials))
                process.stdin.close()
                selector = selectors.DefaultSelector()
                selector.register(process.stdout, selectors.EVENT_READ)
                assert selector.select(10)
                ready = json.loads(process.stdout.readline())
                if source == "hardware":
                    assert ready.get("test_only_hardware_double") is True
                clients = {
                    role: Client(ready["url"], token, "quota", protocol="2026-07-28", accepted_sources=(source,))
                    for role, token in credentials.items()
                }
                for client in clients.values():
                    client.discover(versions=("1.4",) if source == "hardware" else ("1.3",))
                owner, display = clients["owner"], clients["display"]
                owner.feedback("pushEncoder.1.1", "value", 1)
                quota_error = "invalid_argument" if source == "hardware" else "rate_limited"
                denied(lambda: owner.feedback("pushEncoder.1.1", "value", 2), quota_error)
                display.feedback("pushEncoder.1.1", "value", 3)
                display.feedback("pushEncoder.1.1", "value", 4)
                denied(lambda: display.feedback("pushEncoder.1.1", "value", 5), quota_error)
                denied(lambda: clients["operator"].feedback("pushEncoder.1.1", "value", 6), "http_403")
                snapshot = owner.snapshot()
                assert snapshot["latest_sequence"] == "3"
                assert snapshot["latest_input_sequence"] == "0"
                cases.append(
                    {
                        "name": source + "_explicit_display_bucket_isolated_from_owner_and_scope_unchanged",
                        "passed": True,
                    }
                )
            finally:
                process.terminate()
                process.wait(timeout=5)
                process.stdout.close()
        assert all(token not in (directory / "stderr.log").read_text() for token in credentials.values())
    report = {
        "passed_count": len(cases),
        "failed_count": 0,
        "skipped_count": 0,
        "cases": cases,
        "scope": "No physical device; default legacy scope/aggregate tested separately by verify_surface_clients_transport.py",
    }
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
