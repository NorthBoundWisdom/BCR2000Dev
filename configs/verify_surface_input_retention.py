#!/usr/bin/env python3
"""Explicit 1.5 real-process retention probes; Mock and Debug-only device double, never CoreMIDI."""

from __future__ import annotations

import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def reject(action, code, error_type):
    try:
        action()
    except error_type as failure:
        assert failure.code == code, (failure.code, code)
    else:
        raise AssertionError("Expected " + code)


class Host:
    def __init__(self, binary, directory, flags, *, hardware=False):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=False)
        self.tokens = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
        environment = {key: value for key, value in os.environ.items() if key != "BCR_PROVIDER_TOKEN"}
        self.script, self.device = directory / "TEST-ONLY-commands.json", directory / "TEST-ONLY-device.json"
        self.commands = []
        if hardware:
            self.script.write_text("[]")
            environment.update(
                BCR_PROVIDER_TEST_HARDWARE="1",
                BCR_PROVIDER_TEST_HARDWARE_SCRIPT=str(self.script),
                BCR_PROVIDER_TEST_HARDWARE_REPORT=str(self.device),
            )
        self.log = (directory / "stderr.log").open("w")
        self.process = subprocess.Popen(
            [
                str(binary),
                "--port",
                "0",
                "--surface-instance-id",
                "retained-process",
                "--surface-client-tokens-stdin",
                *flags,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.log,
            text=True,
            env=environment,
        )
        try:
            self.process.stdin.write(json.dumps(self.tokens))
            self.process.stdin.close()
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                assert selector.select(10), "Retained provider did not announce readiness"
                self.ready = json.loads(self.process.stdout.readline())
            assert self.ready["event"] == "provider.ready"
        except BaseException:
            self.stop()
            raise

    def client(self, role="owner", protocol="2026-07-28", hardware=False):
        from surface_control import Client

        return Client(
            self.ready["url"],
            self.tokens[role],
            "retained-process",
            protocol=protocol,
            accepted_sources=("hardware",) if hardware else ("simulation",),
            provider_id=self.ready["provider_id"],
            provider_header="BCR-Provider-Id",
        )

    def command(self, step):
        self.commands.append(step)
        temporary = self.script.with_suffix(".new")
        temporary.write_text(json.dumps(self.commands))
        temporary.replace(self.script)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.device.exists() and json.loads(self.device.read_text()).get("consumed", 0) >= len(self.commands):
                return
            time.sleep(0.005)
        raise AssertionError("Owned test-double command was not consumed")

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        self.process.wait(timeout=5)
        self.process.stdout.close()
        self.log.close()
        evidence = (self.directory / "stderr.log").read_text()
        assert all(token not in evidence for token in self.tokens.values()), "Credential leaked into evidence"


def input_page(client, after="0", limit=128, expected=None):
    return client.call(
        "surface_control_input_events",
        {"expected": expected or client.expected, "after_input_sequence": after, "limit": limit},
    )


def verify_simulation(binary, directory):
    from surface_control import InputEventCursor, SurfaceError

    directory.mkdir(parents=True, exist_ok=False)
    cases = []
    for protocol in ("2026-07-28", "2025-11-25"):
        base = retained = None
        try:
            base = Host(binary, directory / (protocol + "-default"), ["--simulation-profile"])
            retained = Host(
                binary,
                directory / (protocol + "-retained"),
                [
                    "--simulation-profile",
                    "--surface-input-event-capacity",
                    "4",
                    "--allow-surface-input",
                    "--allow-surface-feedback",
                    "--allow-surface-reset",
                    "--allow-device-control",
                    "--allow-simulation-control",
                    "--write-limit",
                    "10000",
                ],
            )
            old = base.client(protocol=protocol)
            current = retained.client(protocol=protocol)
            assert old.discover()["contract_version"] == "1.3"
            assert current.discover()["contract_version"] == "1.5"
            if protocol == "2026-07-28":
                legacy_archive = ROOT / "Tests/Fixtures/SurfaceSDK/surface-control-sdk-1.4.0.zip"
                import hashlib

                assert (
                    hashlib.sha256(legacy_archive.read_bytes()).hexdigest()
                    == "c277eb0a78c2dc165aac7ab0384c00853376bf119df5906f65d8e724c6a9423e"
                )
                probe = """
import json, sys
settings = json.load(sys.stdin)
sys.path.insert(0, settings['sdk'])
import surface_control
assert surface_control.__version__ == '1.4.0' and surface_control.__file__.startswith(settings['sdk'] + '/')
for url, token, version in settings['hosts']:
    client = surface_control.Client(url, token, 'retained-process')
    try:
        discovery = client.discover()
    except surface_control.SurfaceError as error:
        assert version == '1.5' and error.code == 'unsupported_contract'
    else:
        assert version == '1.3' and discovery['contract_version'] == '1.3'
        client.snapshot()
print(json.dumps({'real_sdk': '1.4.0', 'default13_accepted': True, 'explicit15_rejected': True}))
"""
                evidence = subprocess.run(
                    [sys.executable, "-B", "-c", probe],
                    text=True,
                    capture_output=True,
                    check=True,
                    input=json.dumps(
                        {
                            "sdk": str(legacy_archive),
                            "hosts": [
                                [base.ready["url"], base.tokens["owner"], "1.3"],
                                [retained.ready["url"], retained.tokens["owner"], "1.5"],
                            ],
                        }
                    ),
                    timeout=10,
                )
                cases.append(
                    {
                        "name": "frozen_real_sdk14_default13_and_explicit15",
                        "passed": True,
                        **json.loads(evidence.stdout),
                    }
                )
            old_tools, new_tools = old.rpc("tools/list", {})["tools"], current.rpc("tools/list", {})["tools"]
            assert [tool for tool in new_tools if tool["name"] != "surface_control_input_events"] == old_tools
            assert len(new_tools) == len(old_tools) + 1
            assert new_tools[-1]["annotations"]["readOnlyHint"] is True
            reads = {"surface_control_discover", "surface_control_snapshot", "surface_control_events"}
            for role, writes in [
                ("operator", {"surface_control_input", "surface_control_renew"}),
                ("display", {"surface_control_feedback"}),
            ]:
                scoped = retained.client(role, protocol)
                scoped.discover()
                assert {tool["name"] for tool in scoped.rpc("tools/list", {})["tools"]} == reads | writes | {
                    "surface_control_input_events"
                }
                assert input_page(scoped)["input_event_capacity"] == 4
                rejected = base.client(role, protocol)
                rejected.discover()
                reject(lambda: input_page(rejected), "http_403", SurfaceError)
            cursor = InputEventCursor(current, limit=2)
            cursor.bootstrap(current.snapshot())
            current.input("pushEncoder.1.1", "scalar", 20)
            ignored = current.input("pushEncoder.1.1", "scalar", 20)
            assert ignored["disposition"] == "ignored"
            current.input("button.1.3", "boolean", True, hold_s=0.05)
            before_renew = current.latest_input_sequence
            current.renew("button.1.3", 0.05)
            assert current.snapshot()["latest_input_sequence"] == before_renew
            deadline = time.monotonic() + 5
            while current.snapshot()["inputs"]["button.1.3"]:
                assert time.monotonic() < deadline, "Expiry not processed"
                time.sleep(0.005)
            if protocol == "2026-07-28":
                for _ in range(1026):
                    current.feedback("button.1.1", "indicator", "on")
                reject(
                    lambda: current.call(
                        "surface_control_events",
                        {
                            "instance_id": current.instance_id,
                            "epoch": current.expected["epoch"],
                            "after_sequence": "0",
                            "limit": 1024,
                        },
                    ),
                    "event_gap",
                    SurfaceError,
                )
            first = cursor.poll()
            highwater = int(current.latest_sequence)
            current.feedback("button.1.1", "indicator", "off")
            second = cursor.poll()
            rows = [entry["event"] for entry in first + second]
            assert [row["input_sequence"] for row in rows] == ["1", "2", "3", "4"]
            assert rows[1]["disposition"] == "ignored" and rows[-1]["reason"] == "hold_expired"
            assert int(current.latest_sequence) >= highwater and cursor.input_sequence == 4
            for value in (21, 22, 23, 24, 25):
                current.input("pushEncoder.1.1", "scalar", value)
            reject(lambda: input_page(current), "input_event_gap", SurfaceError)
            previous = dict(current.expected)
            current.reset()
            page = input_page(current)
            assert page["events"] == [] and page["input_event_capacity"] == 4 and page["latest_input_sequence"] == "0"
            reject(lambda: input_page(current, expected=previous), "stale_epoch", SurfaceError)
            cases.append(
                {
                    "name": "retention_roles_history_cas_reset_" + protocol,
                    "passed": True,
                    "feedback_flood": 1026 if protocol == "2026-07-28" else 0,
                    "accepted_ignored_expiry_preserved": True,
                    "capacity_survived_reset": 4,
                }
            )
        finally:
            if retained is not None:
                retained.stop()
            if base is not None:
                base.stop()
    for arguments in [
        ["--simulation-profile", "--surface-input-event-capacity", value] for value in ("0", "65537", "-1", "bad")
    ] + [
        ["--simulation-profile", "--surface-input-event-capacity", "2", "--surface-input-event-capacity", "3"],
        ["--surface-input-event-capacity", "4"],
        ["--no-console", "--surface-input-event-capacity", "4"],
    ]:
        result = subprocess.run([str(binary), "--describe-surface", *arguments], capture_output=True, timeout=5)
        assert result.returncode == 2
    for value in ("1", "65536"):
        description = json.loads(
            subprocess.check_output(
                [str(binary), "--simulation-profile", "--surface-input-event-capacity", value, "--describe-surface"]
            )
        )
        assert description["discovery"]["contract_version"] == "1.5" and len(description["tools"]) == 8
    cases.append({"name": "capacity_cli_bounds_duplicates_and_explicit_profile", "passed": True})
    (directory / "report.json").write_text(
        json.dumps({"passed": True, "cases": cases, "hardware_verified": False}, indent=2) + "\n"
    )
    return cases


def verify_hardware(binary, directory):
    from surface_control import SurfaceError

    directory.mkdir(parents=True, exist_ok=False)
    mapping = directory / "TEST-ONLY-map.json"
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
    cases = []
    for policy in ("observe", "write"):
        for allowed in (False, True):
            flags = [
                "--source",
                "hardware",
                "--hardware-profile",
                "--hardware-map",
                str(mapping),
                "--hardware-output",
                policy,
                "--surface-input-event-capacity",
                "2",
            ]
            if allowed:
                flags.append("--allow-surface-feedback")
            host = Host(binary, directory / (policy + str(allowed)), flags, hardware=True)
            try:
                client = host.client(hardware=True)
                discovery = client.discover(versions=("1.5",))
                assert discovery["contract_version"] == "1.5" and discovery["source"] == "hardware"
                assert "events.input_retention" in discovery["profile"]["capabilities"]
                deadline = time.monotonic() + 5
                while not host.device.exists():
                    assert time.monotonic() < deadline, "Test double did not initialize its report"
                    time.sleep(0.005)
                assert json.loads(host.device.read_text())["sent"] == [], "Startup replayed hardware displays"
                assert client.snapshot()["inputs"] == {}
                host.command({"operation": "input", "cc": 8, "value": 45})
                page = input_page(client)
                assert page["input_event_capacity"] == 2 and page["events"][0]["origin"] == "hardware"
                client.snapshot()
                expected = dict(client.expected)
                for suffix, fields, code in [
                    (
                        "input",
                        {
                            "expected_input_sequence": client.latest_input_sequence,
                            "control_id": "pushEncoder.1.1",
                            "encoding": "scalar",
                            "value": 1,
                        },
                        "permission_denied",
                    ),
                    ("renew", {"control_id": "pushEncoder.1.1", "hold_s": 1}, "unsupported_hold"),
                    ("reset", {"expected_sequence": client.latest_sequence}, "unsupported_tool"),
                ]:
                    reject(
                        lambda suffix=suffix, fields=fields: client.call(
                            "surface_control_" + suffix, {"expected": expected, **fields}
                        ),
                        code,
                        SurfaceError,
                    )
                before = len(json.loads(host.device.read_text())["sent"])
                if policy == "write" and allowed:
                    client.feedback("pushEncoder.1.1", "value", 64)
                else:
                    reject(lambda: client.feedback("pushEncoder.1.1", "value", 64), "permission_denied", SurfaceError)
                after = len(json.loads(host.device.read_text())["sent"])
                assert after - before == int(policy == "write" and allowed)
                host.command({"operation": "disconnect"})
                client = host.client(hardware=True)
                client.discover(versions=("1.5",))
                reject(lambda: input_page(client, expected=expected), "stale_epoch", SurfaceError)
                assert input_page(client)["events"] == [] and input_page(client)["input_event_capacity"] == 2
                assert client.snapshot()["inputs"] == {}
                host.command({"operation": "reconnect"})
                client = host.client(hardware=True)
                client.discover(versions=("1.5",))
                assert input_page(client)["events"] == [] and client.snapshot()["inputs"] == {}
                assert len(json.loads(host.device.read_text())["sent"]) == after
                cases.append(
                    {
                        "name": "hardware_retention_" + policy + "_" + str(allowed),
                        "passed": True,
                        "capacity_survived_transition": 2,
                        "remote_mutations_rejected": 3,
                        "lifecycle_sends": 0,
                        "hardware_verified": False,
                    }
                )
            finally:
                host.stop()
    (directory / "report.json").write_text(
        json.dumps({"passed": True, "cases": cases, "hardware_verified": False}, indent=2) + "\n"
    )
    return cases
