#!/usr/bin/env python3
"""Multiple private display roles, conflict provenance and quota isolation in real no-device processes."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "build/seed/SurfacePlugins/clients/python"))
from surface_control import Client, SurfaceError  # noqa: E402


def rejected(action, code):
    try:
        action()
    except SurfaceError as error:
        assert error.code == code, (error.code, code)
    else:
        raise AssertionError("Expected exact rejection")


def fresh(extra=None):
    value = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
    if extra is not None:
        value["displays"] = [secrets.token_hex(32) for _ in range(extra)]
    return value


def payload(record, size=None):
    value = json.dumps(record)
    return value + " " * max(0, (size or 0) - len(value))


def all_tokens(record):
    return [record[role] for role in ("owner", "operator", "display")] + record.get("displays", [])


@contextmanager
def host(binary, directory, source, record, flags=(), size=None):
    directory.mkdir(parents=True, exist_ok=False)
    env = {key: value for key, value in os.environ.items() if key != "BCR_PROVIDER_TOKEN"}
    command = [
        str(binary),
        "--port",
        "0",
        "--surface-instance-id",
        "multi",
        "--surface-client-tokens-stdin",
        "--allow-surface-feedback",
        *flags,
    ]
    if source == "hardware":
        mapping, commands = directory / "TEST-ONLY-map.json", directory / "commands.json"
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
        commands.write_text("[]")
        env.update(
            BCR_PROVIDER_TEST_HARDWARE="1",
            BCR_PROVIDER_TEST_HARDWARE_SCRIPT=str(commands),
            BCR_PROVIDER_TEST_HARDWARE_REPORT=str(directory / "device.json"),
        )
        command += [
            "--source",
            "hardware",
            "--hardware-profile",
            "--hardware-map",
            str(mapping),
            "--hardware-output",
            "write",
        ]
    else:
        command += ["--simulation-profile", "--allow-device-control", "--allow-surface-input"]
    with (directory / "stderr.log").open("w") as stderr:
        process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, env=env, cwd="/tmp", text=True
        )
        try:
            process.stdin.write(payload(record, size))
            process.stdin.close()
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(10), "Provider not ready"
            ready = json.loads(process.stdout.readline())
            if source == "hardware":
                assert ready.get("test_only_hardware_double") is True
            clients = {
                role: Client(ready["url"], record[role], "multi", protocol="2026-07-28", accepted_sources=(source,))
                for role in ("owner", "operator", "display")
            }
            extras = [
                Client(ready["url"], token, "multi", protocol="2026-07-28", accepted_sources=(source,))
                for token in record.get("displays", [])
            ]
            for client in [*clients.values(), *extras]:
                client.discover(versions=("1.4",) if source == "hardware" else ("1.3",))
            yield clients, extras, ready
        finally:
            process.terminate()
            process.wait(timeout=5)
            process.stdout.close()
    assert all(token not in (directory / "stderr.log").read_text() for token in all_tokens(record))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    binary, output = args.binary.resolve(), args.output.resolve()
    cases = []
    for source in ("simulation", "hardware"):
        record = fresh(1)
        directory = output / source
        with host(binary, directory, source, record, ("--display-write-limit", "2", "--write-limit", "1")) as (
            clients,
            extras,
            ready,
        ):
            owner, operator, first, second = clients["owner"], clients["operator"], clients["display"], extras[0]
            catalogue = owner.rpc("tools/list", {})["tools"]
            names = {
                "surface_control_discover",
                "surface_control_snapshot",
                "surface_control_events",
                "surface_control_feedback",
            }
            for client in (first, second):
                listed = client.rpc("tools/list", {})["tools"]
                assert {row["name"] for row in listed} == names
                assert listed == [row for row in catalogue if row["name"] in names]
                rejected(
                    lambda: client.call(
                        "surface_control_input",
                        {
                            "expected": client.expected,
                            "control_id": "pushEncoder.1.1",
                            "encoding": "scalar",
                            "value": 1,
                        },
                    ),
                    "http_403",
                )
                rejected(lambda: client.call("surface_control_reset", {}), "http_403")
            quota_error = "invalid_argument" if source == "hardware" else "rate_limited"
            if source == "simulation":
                owner_event = owner.input("pushEncoder.1.1", "scalar", 45)
                rejected(lambda: operator.input("pushEncoder.1.2", "scalar", 46), "stale_input_sequence")
                operator.refresh_input_sequence()
                rejected(lambda: operator.input("pushEncoder.1.2", "scalar", 46), quota_error)
            else:
                owner_event = owner.feedback("pushEncoder.1.1", "value", 5)
                rejected(lambda: owner.feedback("pushEncoder.1.1", "value", 6), quota_error)
            a = first.feedback("pushEncoder.1.1", "value", 10)
            b = second.feedback("pushEncoder.1.1", "value", 20)
            assert len({owner_event["writer_id"], a["writer_id"], b["writer_id"]}) == 3
            assert owner.snapshot()["feedback"]["pushEncoder.1.1"]["value"] == 20
            a2 = first.feedback("pushEncoder.1.1", "value", 11)
            rejected(lambda: first.feedback("pushEncoder.1.1", "value", 12), quota_error)
            b2 = second.feedback("pushEncoder.1.1", "value", 21)
            assert a2["writer_id"] == a["writer_id"] and b2["writer_id"] == b["writer_id"]
            same = Client(ready["url"], record["display"], "multi", protocol="2026-07-28", accepted_sources=(source,))
            same.discover(versions=("1.4",) if source == "hardware" else ("1.3",))
            rejected(lambda: same.feedback("pushEncoder.1.1", "value", 13), quota_error)
            snapshot = owner.snapshot()
            assert snapshot["feedback"]["pushEncoder.1.1"]["value"] == 21
            assert snapshot["latest_input_sequence"] == ("1" if source == "simulation" else "0")
            page = owner.call(
                "surface_control_events",
                {"instance_id": "multi", "epoch": owner.expected["epoch"], "after_sequence": "0", "limit": 1024},
            )
            assert [row["writer_id"] for row in page["events"]] == [
                owner_event["writer_id"],
                a["writer_id"],
                b["writer_id"],
                a["writer_id"],
                b["writer_id"],
            ]
            assert len(page["events"]) == 5
            assert owner.rpc("tools/list", {})["tools"] == catalogue
            cases.append(
                {"name": source + "_two_displays_shared_target_last_accepted_wins_and_writers_visible", "passed": True}
            )
            cases.append(
                {
                    "name": source + "_each_display_quota_isolated_owner_operator_unchanged_same_token_shares_quota",
                    "passed": True,
                }
            )
            (directory / "events.json").write_text(json.dumps(page, indent=2) + "\n")
        if source == "hardware":
            assert json.loads((directory / "device.json").read_text())["sent"] == [
                [176, 1, value] for value in (5, 10, 20, 11, 21)
            ]
    for source in ("simulation", "hardware"):
        directory = output / ("concurrent-" + source)
        with host(binary, directory, source, fresh(1), ("--display-write-limit", "100", "--write-limit", "1")) as (
            clients,
            extras,
            _,
        ):
            owner = clients["owner"]
            results, failures, intervals = [[], []], [], [None, None]

            def write(index, client):
                began = time.monotonic()
                try:
                    for offset in range(16):
                        results[index].append(client.feedback("pushEncoder.1.1", "value", 20 + 40 * index + offset))
                except Exception as failure:
                    failures.append(type(failure).__name__)
                finally:
                    intervals[index] = (began, time.monotonic())

            threads = [
                threading.Thread(target=write, args=(i, client))
                for i, client in enumerate((clients["display"], extras[0]))
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=10)
            assert not failures and all(not thread.is_alive() for thread in threads)
            assert max(interval[0] for interval in intervals) < min(interval[1] for interval in intervals)
            assert [len(group) for group in results] == [16, 16]
            writers = [{event["writer_id"] for event in group} for group in results]
            assert all(len(group) == 1 for group in writers) and writers[0].isdisjoint(writers[1])
            page = owner.call(
                "surface_control_events",
                {"instance_id": "multi", "epoch": owner.expected["epoch"], "after_sequence": "0", "limit": 1024},
            )
            assert len(page["events"]) == 32
            assert owner.snapshot()["feedback"]["pushEncoder.1.1"]["value"] == page["events"][-1]["value"]
            assert {event["writer_id"] for event in page["events"]} == writers[0] | writers[1]
            (directory / "events.json").write_text(json.dumps(page, indent=2) + "\n")
            cases.append(
                {
                    "name": source + "_simultaneous_two_display_clients_keep_provenance",
                    "passed": True,
                    "events": 32,
                    "overlapping_call_intervals": True,
                }
            )
        if source == "hardware":
            assert json.loads((directory / "device.json").read_text())["sent"] == [
                [176, 1, event["value"]] for event in page["events"]
            ]
    maximum = fresh(7)
    with host(binary, output / "max-eight", "simulation", maximum, ("--write-limit", "1"), size=2048) as (
        clients,
        extras,
        _,
    ):
        responses = [
            client.feedback("pushEncoder.1.1", "value", index)
            for index, client in enumerate([clients["display"], *extras])
        ]
        assert len({row["writer_id"] for row in responses}) == 8
        clients["owner"].refresh_input_sequence()
        clients["owner"].input("pushEncoder.1.1", "scalar", 45)
        cases.append(
            {"name": "eight_display_roles_exact2048_default_independent_quota_and_owner_budget", "passed": True}
        )
    legacy = fresh()
    with host(binary, output / "legacy512", "simulation", legacy, ("--write-limit", "1"), size=512) as (clients, _, _):
        clients["display"].feedback("pushEncoder.1.1", "value", 10)
        rejected(lambda: clients["display"].feedback("pushEncoder.1.1", "value", 11), "rate_limited")
        rejected(lambda: clients["owner"].feedback("pushEncoder.1.1", "value", 12), "rate_limited")
        cases.append({"name": "legacy_three_role_exact512_shared_aggregate_unchanged", "passed": True})
    invalid = [
        ("empty", {**maximum, "displays": []}),
        ("too-many", {**maximum, "displays": maximum["displays"] + [secrets.token_hex(32)]}),
        ("string", {**maximum, "displays": "bad"}),
        ("boolean", {**maximum, "displays": [True]}),
        ("null", {**maximum, "displays": None}),
        ("owner-collision", {**maximum, "displays": [maximum["owner"]]}),
        ("operator-collision", {**maximum, "displays": [maximum["operator"]]}),
        ("display-collision", {**maximum, "displays": [maximum["display"]]}),
        ("extra-collision", {**maximum, "displays": maximum["displays"][:1] * 2}),
        ("short", {**maximum, "displays": ["short"]}),
        ("unknown", {**maximum, "other": 1}),
    ]
    raw_invalid = [(name, json.dumps(record)) for name, record in invalid]
    valid = json.dumps(maximum)
    raw_invalid += [
        ("duplicate-array", valid[:-1] + ',"displays":[]}'),
        ("escaped-duplicate", valid[:-1] + ',"displ\\u0061ys":[]}'),
        ("legacy513", payload(legacy, 513)),
        ("extended2049", payload(maximum, 2049)),
    ]
    env = {key: value for key, value in os.environ.items() if key != "BCR_PROVIDER_TOKEN"}
    for name, raw in raw_invalid:
        result = subprocess.run(
            [str(binary), "--surface-client-tokens-stdin"],
            input=raw,
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert result.returncode == 2
        assert all(token not in result.stdout + result.stderr for token in all_tokens(maximum) + all_tokens(legacy))
        cases.append({"name": name + "_fails_closed_without_echo", "passed": True})
    report = {
        "passed_count": len(cases),
        "failed_count": 0,
        "skipped_count": 0,
        "cases": cases,
        "scope": "Real processes with simulation/Debug hardware double only; no physical MIDI qualification",
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
