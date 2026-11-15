#!/usr/bin/env python3
"""Real-process proof of opt-in operator/display credentials; no device access."""

from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "build/seed/SurfacePlugins/clients/python"))
from surface_control import Client, SurfaceError  # noqa: E402


def denied(action, code):
    try:
        action()
    except SurfaceError as failure:
        assert failure.code == code, failure.code
    else:
        raise AssertionError("Expected fixed rejection")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve()
    cases = []
    clean_env = {key: value for key, value in os.environ.items() if key != "BCR_PROVIDER_TOKEN"}
    for protocol in ("2026-07-28", "2025-11-25"):
        values = {name: secrets.token_hex(32) for name in ("owner", "operator", "display")}
        label = protocol
        with (args.output / (label + ".stderr.log")).open("w") as stderr:
            host = subprocess.Popen(
                [
                    str(binary),
                    "--port",
                    "0",
                    "--simulation-profile",
                    "--surface-instance-id",
                    "roles",
                    "--allow-device-control",
                    "--allow-surface-input",
                    "--allow-surface-feedback",
                    "--surface-client-tokens-stdin",
                ],
                cwd=tempfile.gettempdir(),
                env=clean_env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr,
                text=True,
            )
            try:
                host.stdin.write(json.dumps(values))
                host.stdin.close()
                selector = selectors.DefaultSelector()
                selector.register(host.stdout, selectors.EVENT_READ)
                assert selector.select(10), "not ready"
                ready = json.loads(host.stdout.readline())
                clients = {
                    role: Client(ready["url"], token, "roles", protocol=protocol) for role, token in values.items()
                }
                for client in clients.values():
                    client.discover()
                operator, display, owner = (clients[role] for role in ("operator", "display", "owner"))
                first = operator.input("pushEncoder.1.1", "scalar", 45)
                feedback = display.feedback("button.1.1", "indicator", "on")
                owner.refresh_input_sequence()
                owner_event = owner.input("pushEncoder.1.2", "scalar", 63)
                assert len({first["writer_id"], feedback["writer_id"], owner_event["writer_id"]}) == 3
                denied(lambda: display.input("pushEncoder.1.1", "scalar", 46), "http_403")
                denied(lambda: display.renew("button.1.3", 1), "http_403")
                denied(lambda: operator.feedback("button.1.1", "indicator", "off"), "http_403")
                for client in (operator, display):
                    denied(client.reset, "http_403")
                    denied(
                        lambda c=client: c.rpc(
                            "tools/call", {"name": "set_parameter", "arguments": {"id": "simulation.arm", "value": 1}}
                        ),
                        "http_403",
                    )
                operator.refresh_input_sequence()
                held = operator.input("button.1.3", "boolean", True, hold_s=1)
                renewed = operator.renew("button.1.3", 1)
                assert renewed["hold_deadline"] >= held["hold_deadline"]
                operator.refresh_input_sequence()
                released = operator.input("button.1.3", "boolean", False)
                assert released["writer_id"] == first["writer_id"]
                page = owner.call(
                    "surface_control_events",
                    {"instance_id": "roles", "epoch": owner.expected["epoch"], "after_sequence": "0", "limit": 1024},
                )
                assert {e["writer_id"] for e in page["events"]} == {
                    first["writer_id"],
                    feedback["writer_id"],
                    owner_event["writer_id"],
                }
                failures = []

                def write_inputs():
                    try:
                        for index in range(12):
                            operator.input("pushEncoder.1.1", "scalar", 70 + index)
                    except Exception:
                        failures.append("input")

                def write_displays():
                    try:
                        for index in range(12):
                            display.feedback("button.1.2", "indicator", "on" if index % 2 else "off")
                    except Exception:
                        failures.append("display")

                threads = [threading.Thread(target=write_inputs), threading.Thread(target=write_displays)]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join(timeout=10)
                assert not failures and all(not thread.is_alive() for thread in threads)
                concurrent = owner.call(
                    "surface_control_events",
                    {
                        "instance_id": "roles",
                        "epoch": owner.expected["epoch"],
                        "after_sequence": page["latest_sequence"],
                        "limit": 1024,
                    },
                )
                assert len(concurrent["events"]) == 24
                assert all(
                    e["writer_id"] == (first["writer_id"] if e["kind"] == "input" else feedback["writer_id"])
                    for e in concurrent["events"]
                )
                # A direct owner legacy call after each secondary request retains owner authority/context.
                assert not owner.rpc("tools/call", {"name": "provider_state", "arguments": {}}).get("isError", False)
                cases.append(
                    {
                        "name": "scoped_roles_distinct_writers_" + protocol,
                        "passed": True,
                        "writer_count": 3,
                        "secondary_legacy_and_reset_denied": True,
                    }
                )
            finally:
                host.terminate()
                host.wait(timeout=5)
                host.stdout.close()
            evidence = "".join(path.read_text() for path in args.output.glob("*.log"))
            assert all(token not in evidence for token in values.values()), "credential in evidence"
    # Invalid/repeated/unknown keys and old-input conflicts fail without echoing provisioning.
    examples = [
        ("duplicate", '{"owner":"A","owner":"B","operator":"C","display":"D"}', []),
        ("unknown", json.dumps({**values, "extra": "x"}), []),
        ("missing", json.dumps({"owner": values["owner"]}), []),
        ("same", json.dumps({key: values["owner"] for key in values}), []),
        ("oversize", " " * 513, []),
        ("stdin-conflict", json.dumps(values), ["--token-stdin"]),
    ]
    for label, payload, flags in examples:
        result = subprocess.run(
            [str(binary), "--surface-client-tokens-stdin", *flags],
            input=payload,
            env=clean_env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == 2
        assert all(token not in result.stdout + result.stderr for token in values.values())
        cases.append({"name": label + "_fails_closed_without_credentials", "passed": True})
    result = subprocess.run(
        [str(binary), "--surface-client-tokens-stdin"],
        input=json.dumps(values),
        env={**clean_env, "BCR_PROVIDER_TOKEN": values["owner"]},
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert result.returncode == 2 and all(t not in result.stdout + result.stderr for t in values.values())
    cases.append({"name": "legacy_environment_conflict", "passed": True})
    with open(os.devnull) as not_a_pipe:
        result = subprocess.run(
            [str(binary), "--surface-client-tokens-stdin"],
            stdin=not_a_pipe,
            env=clean_env,
            capture_output=True,
            text=True,
            timeout=5,
        )
    assert result.returncode == 2 and all(t not in result.stdout + result.stderr for t in values.values())
    cases.append({"name": "non_pipe_stdin_refused", "passed": True})
    values = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
    with (args.output / "budget.stderr.log").open("w") as stderr:
        host = subprocess.Popen(
            [
                str(binary),
                "--port",
                "0",
                "--simulation-profile",
                "--surface-instance-id",
                "budget",
                "--allow-device-control",
                "--allow-surface-input",
                "--allow-surface-feedback",
                "--write-limit",
                "2",
                "--surface-client-tokens-stdin",
            ],
            env=clean_env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr,
            text=True,
        )
        try:
            host.stdin.write(json.dumps(values))
            host.stdin.close()
            selector = selectors.DefaultSelector()
            selector.register(host.stdout, selectors.EVENT_READ)
            assert selector.select(10)
            ready = json.loads(host.stdout.readline())
            clients = {role: Client(ready["url"], token, "budget") for role, token in values.items()}
            for client in clients.values():
                client.discover()
            denied(lambda: clients["display"].input("pushEncoder.1.1", "scalar", 1), "http_403")
            clients["operator"].input("pushEncoder.1.1", "scalar", 45)
            clients["display"].feedback("button.1.1", "indicator", "on")
            clients["owner"].refresh_input_sequence()
            denied(lambda: clients["owner"].input("pushEncoder.1.2", "scalar", 50), "rate_limited")
            cases.append(
                {
                    "name": "one_aggregate_budget_across_secondary_and_owner",
                    "passed": True,
                    "limit_per_second": 2,
                    "successful_writes": 2,
                    "denied_scope_consumed_quota": False,
                }
            )
        finally:
            host.terminate()
            host.wait(timeout=5)
            host.stdout.close()
    assert all(
        token not in "".join(path.read_text() for path in args.output.glob("*.log")) for token in values.values()
    )
    summary = {
        "passed_count": len(cases),
        "failed_count": 0,
        "skipped_count": 0,
        "cases": cases,
        "device_scope": "Mock only; credentials sent through private anonymous pipe and held in memory",
    }
    (args.output / "report.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
