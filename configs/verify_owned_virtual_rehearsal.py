#!/usr/bin/env python3
"""Actual Release/CoreMIDI owned-endpoint rehearsal; never enumerates or connects physical endpoints."""

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
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from configs.surface_sdk_metadata import verify_manifest  # noqa: E402
from configs.check_owned_virtual_boundary import check as check_source_boundary  # noqa: E402

sys.dont_write_bytecode = True


def wait(condition, message):
    deadline = time.monotonic() + 5
    while not condition():
        assert time.monotonic() < deadline, message
        time.sleep(0.005)


def reject(action, code, error):
    try:
        action()
    except error as failure:
        assert failure.code == code, (failure.code, code)
    else:
        raise AssertionError("Expected " + code)


def run(artifact, output):
    output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((artifact / "manifest.json").read_text())
    sdk, version = verify_manifest(artifact, manifest)
    assert version == "1.5.0" and manifest["configuration"] == "release", "Use an actual Release artifact"
    assert check_source_boundary() == []
    sys.path.insert(0, str(sdk))
    from surface_control import Client, SurfaceError
    from surface_control_diagnostics import ReadOnlyClient, capture, verify

    binary = artifact / "BCRProviderService"
    mapping = output / "TEST-ONLY-map.json"
    mapping.write_text(
        json.dumps(
            {
                "version": 7,
                "entries": [
                    {
                        "control": {"section": "encoder", "row": 1, "index": 1},
                        "midi": {"kind": "controlChange", "channel": 0, "number": 81},
                    },
                    {
                        "control": {"section": "button", "row": 1, "index": 1},
                        "midi": {"kind": "controlChange", "channel": 0, "number": 82},
                        "pressMode": "momentary",
                    },
                ],
            }
        )
    )
    configuration = output / "TEST-ONLY-configuration.json"
    configuration.write_text(
        json.dumps(
            {
                "version": 7,
                "name": "Owned virtual nonphysical fixture",
                "pages": [],
                "macros": [],
                "parameters": [
                    {
                        "id": "test.axis",
                        "name": "Axis",
                        "minimum": 0,
                        "maximum": 127,
                        "defaultValue": 0,
                        "kind": "continuous",
                        "agentWritable": True,
                        "externallyProtected": False,
                    }
                ],
                "assignments": [
                    {
                        "control": {"section": "encoder", "row": 1, "index": 1},
                        "target": {"parameter": {"_0": "test.axis"}},
                        "buttonBehavior": "toggle",
                        "inverted": False,
                    }
                ],
            }
        )
    )
    common = [
        "--source",
        "hardware",
        "--hardware-profile",
        "--hardware-map",
        str(mapping),
        "--configuration",
        str(configuration),
    ]
    normal = subprocess.check_output([str(binary), "--describe-surface"])
    assert hashlib.sha256(normal).hexdigest() == "f1045e601baa94787c759acc0c08e6c9b3fa293d1c0fa5de1af8e6a71e4e2681"
    static = subprocess.run(
        [str(binary), *common, "--owned-virtual-rehearsal", "--describe-surface"], capture_output=True, check=True
    )
    description = json.loads(static.stdout)["discovery"]
    assert (
        description["profile"]["id"] == "bcr2000.owned-virtual-rehearsal" and description["contract_version"] == "1.5"
    )
    assert "session.owned_virtual_rehearsal" in description["profile"]["capabilities"] and static.stderr == b""
    cases = []
    matrix = [("2026-07-28", policy, allow) for policy in ("observe", "write") for allow in (False, True)] + [
        ("2025-11-25", "write", True)
    ]
    for protocol, policy, allow in matrix:
        label = protocol + "-" + policy + "-" + str(allow)
        directory = output / label
        directory.mkdir()
        tokens = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
        readfd, writefd = os.pipe()
        log = (directory / "stderr.log").open("w")
        environment = {
            key: value
            for key, value in os.environ.items()
            if key != "BCR_PROVIDER_TOKEN" and not key.startswith("BCR_PROVIDER_TEST_HARDWARE")
        }
        command = [
            str(binary),
            *common,
            "--owned-virtual-rehearsal",
            "--owned-virtual-rehearsal-input-fd",
            str(readfd),
            "--surface-input-event-capacity",
            "4",
            "--port",
            "0",
            "--surface-instance-id",
            "owned-release",
            "--hardware-output",
            policy,
            "--allow-device-control",
            "--surface-client-tokens-stdin",
        ]
        if allow:
            command.append("--allow-surface-feedback")
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=log,
            text=True,
            pass_fds=(readfd,),
            env=environment,
        )
        os.close(readfd)
        try:
            process.stdin.write(json.dumps(tokens))
            process.stdin.close()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                assert selector.select(15), "Owned Release provider did not announce readiness"
                ready = json.loads(process.stdout.readline())
            (directory / "ready.json").write_text(json.dumps(ready, indent=2) + "\n")
            assert ready["owned_virtual_rehearsal"] is True and ready["physical_evidence"] is False
            assert ready["factory_usage"] == {"owned": 1, "native": 0}
            assert ready["test_only_hardware_double"] is False and ready["contract_version"] == "1.0"

            def client(role="owner"):
                return Client(
                    ready["url"],
                    tokens[role],
                    "owned-release",
                    accepted_sources=("hardware",),
                    protocol=protocol,
                    provider_id=ready["provider_id"],
                    provider_header="BCR-Provider-Id",
                )

            owner, display = client(), client("display")
            discovery = owner.discover(versions=("1.5",))
            display.discover(versions=("1.5",))
            assert discovery["profile"] == ready["surface_control"]["profile"]
            assert owner.snapshot()["inputs"] == {} and owner.latest_input_sequence == "0"

            def peer(operation, **fields):
                os.write(writefd, (json.dumps({"operation": operation, **fields}) + "\n").encode())

            control = {"section": "encoder", "row": 1, "index": 1}
            peer("input", control=control, value=45)
            wait(lambda: owner.snapshot()["inputs"].get("encoder.1.1") == 45, "Real owned source callback not observed")
            assert owner.latest_input_sequence == "1"
            before = owner.snapshot()
            parameters = owner.rpc("tools/call", {"name": "list_parameters", "arguments": {}})["structuredContent"]
            if policy == "write" and allow:
                display.feedback("encoder.1.1", "value", 64)
            else:
                reject(lambda: display.feedback("encoder.1.1", "value", 64), "permission_denied", SurfaceError)
            assert owner.snapshot()["inputs"] == before["inputs"] and owner.latest_input_sequence == "1"
            assert (
                owner.rpc("tools/call", {"name": "list_parameters", "arguments": {}})["structuredContent"] == parameters
            )
            expected = dict(owner.expected)
            for suffix, fields, code in [
                (
                    "input",
                    {"expected_input_sequence": "1", "control_id": "encoder.1.1", "encoding": "scalar", "value": 1},
                    "permission_denied",
                ),
                ("renew", {"control_id": "encoder.1.1", "hold_s": 1}, "unsupported_hold"),
                ("reset", {"expected_sequence": owner.latest_sequence}, "unsupported_tool"),
            ]:
                reject(
                    lambda suffix=suffix, fields=fields: owner.call(
                        "surface_control_" + suffix, {"expected": expected, **fields}
                    ),
                    code,
                    SurfaceError,
                )
            denied = owner.rpc("tools/call", {"name": "set_device_source", "arguments": {"source": "mock"}})
            assert denied["isError"] is True and owner.snapshot()["discovery"]["source"] == "hardware"
            old = dict(owner.expected)
            peer("disconnect")
            wait(
                lambda: (
                    owner.call("surface_control_snapshot", {"instance_id": "owned-release"})["link"]["state"]
                    == "disconnected"
                ),
                "Owned disconnect not published",
            )
            owner = client()
            owner.discover(versions=("1.5",))
            empty = owner.snapshot()
            assert empty["inputs"] == {} and empty["latest_input_sequence"] == "0"
            reject(
                lambda: owner.call(
                    "surface_control_input_events", {"expected": old, "after_input_sequence": "0", "limit": 128}
                ),
                "stale_epoch",
                SurfaceError,
            )
            assert (
                owner.call(
                    "surface_control_input_events",
                    {"expected": owner.expected, "after_input_sequence": "0", "limit": 128},
                )["input_event_capacity"]
                == 4
            )
            peer("reconnect")
            wait(
                lambda: (
                    owner.call("surface_control_snapshot", {"instance_id": "owned-release"})["link"]["state"]
                    == "connected"
                ),
                "Owned reconnect not published",
            )
            owner = client()
            owner.discover(versions=("1.5",))
            assert owner.snapshot()["inputs"] == {}
            peer("input", control=control, value=46)
            wait(lambda: owner.snapshot()["inputs"].get("encoder.1.1") == 46, "New-generation input missing")
            if protocol == "2026-07-28" and policy == "write" and allow:
                diagnostic = ReadOnlyClient(
                    ready["url"],
                    tokens["owner"],
                    "owned-release",
                    accepted_sources=("hardware",),
                    protocol=protocol,
                    provider_id=ready["provider_id"],
                    provider_header="BCR-Provider-Id",
                )
                document = capture(
                    diagnostic,
                    "bcr2000.owned-virtual-rehearsal",
                    "1.5",
                    required_controls=["encoder.1.1"],
                    limits={
                        "duration_s": 1,
                        "interval_s": 0,
                        "max_polls": 1,
                        "max_events": 32,
                        "max_bytes": 1048576,
                        "max_age_s": 2,
                    },
                )
                assert document["rehearsal"] == {"owned_virtual_rehearsal": True, "physical_evidence": False}
                verification = verify(document)
                assert verification["rehearsal"] == document["rehearsal"]
                (directory / "diagnostic-capture.json").write_text(json.dumps(document, indent=2) + "\n")
                (directory / "diagnostic-verify.json").write_text(json.dumps(verification, indent=2) + "\n")
        finally:
            os.close(writefd)
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
            process.stdout.close()
            log.close()
        rawlog = (directory / "stderr.log").read_text()
        assert all(token not in rawlog for token in tokens.values())
        records = [json.loads(line) for line in rawlog.splitlines() if line.startswith("{")]
        audit = next(
            record for record in reversed(records) if record.get("artifact") == "owned-virtual-rehearsal-audit"
        )
        assert process.returncode == 0 and audit["failures"] == [] and audit["unconfirmed_cleanup_refs"] == []
        created = {(row["kind"], row["ref"], row["owner"]) for row in audit["created_refs"]}
        assert len(created) == 5 and audit["call_counts"]["dispose_owned"] == 5
        for operation in audit["calls"]:
            assert operation["operation"] in {
                "create_client",
                "create_source",
                "create_destination",
                "create_input_port",
                "create_output_port",
                "read_owned_uid",
                "connect_owned_source",
                "disconnect_owned_source",
                "publish_owned_input",
                "send_owned_display",
                "dispose_owned",
            }
            assert all((ref["kind"], ref["ref"], ref["owner"]) in created for ref in operation["refs"])
            assert operation["owned_virtual_rehearsal"] is True and operation["physical_evidence"] is False
        explicit = int(policy == "write" and allow)
        # The old engine intentionally keeps a display overlay across connection epochs.
        # A later genuine input can correct that ring; that is not lifecycle replay.
        input_driven = explicit
        assert audit["call_counts"].get("send_owned_display", 0) == explicit + input_driven
        assert len(audit["display_receipts"]) == explicit + input_driven
        lifecycle = {
            record.get("event"): record["audit"]["call_counts"].get("send_owned_display", 0)
            for record in records
            if record.get("event")
            in {
                "owned_virtual.connected",
                "owned_virtual.disconnected",
                "owned_virtual.reconnected",
                "owned_virtual.stopped",
            }
        }
        assert lifecycle["owned_virtual.connected"] == 0
        assert lifecycle["owned_virtual.disconnected"] == lifecycle["owned_virtual.reconnected"] == explicit
        input_callbacks = [
            record["audit"]["call_counts"].get("send_owned_display", 0)
            for record in records
            if record.get("event") == "owned_virtual.input_callback"
        ]
        assert input_callbacks == [0, explicit + input_driven]
        input_generations = [
            record["connection_generation"]
            for record in records
            if record.get("event") == "owned_virtual.input_callback"
        ]
        assert input_generations == [1, 3]
        sent_plans = [record for record in audit["calls"] if record["operation"] == "send_owned_display"]
        assert [record["generation"] for record in sent_plans] == ([1, 3] if explicit else [])
        assert lifecycle["owned_virtual.stopped"] == input_callbacks[-1]
        if explicit:
            assert audit["display_receipts"] == [[176, 81, 64], [176, 81, 64]]
        assert audit["call_counts"]["publish_owned_input"] == 2
        cases.append(
            {
                "name": label,
                "passed": True,
                "actual_owned_refs": len(created),
                "native_factory_calls": 0,
                "owned_display_sends": explicit + input_driven,
                "explicit_display_sends": explicit,
                "genuine_input_corrections": input_driven,
                "input_generations": input_generations,
                "display_plan_generations": [record["generation"] for record in sent_plans],
                "lifecycle_sends": 0,
                "input_callbacks_after_feedback_unchanged": True,
                "remote_mutations_rejected": 3,
                "owned_virtual_rehearsal": True,
                "physical_evidence": False,
            }
        )
    # Old Debug script escape remains closed in a genuine Release binary.
    denied = subprocess.run(
        [str(binary), *common, "--port", "0"],
        env={**os.environ, "BCR_PROVIDER_TOKEN": secrets.token_hex(32), "BCR_PROVIDER_TEST_HARDWARE": "1"},
        capture_output=True,
        timeout=5,
    )
    assert denied.returncode == 2
    report = {
        "passed_count": len(cases),
        "failed_count": 0,
        "skipped_count": 0,
        "cases": cases,
        "artifact_manifest_sha256": hashlib.sha256((artifact / "manifest.json").read_bytes()).hexdigest(),
        "owned_virtual_rehearsal": True,
        "physical_evidence": False,
        "hardware_qualified": False,
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.artifact.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
