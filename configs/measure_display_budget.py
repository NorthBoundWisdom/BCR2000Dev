#!/usr/bin/env python3
"""60-second real-provider/fake-device display load; never opens a physical MIDI endpoint."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict, deque
from concurrent.futures import ThreadPoolExecutor
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


def distribution(values):
    values = sorted(values)
    if not values:
        return {"count": 0}
    return {
        "count": len(values),
        **{
            name: values[min(len(values) - 1, int((len(values) - 1) * p))]
            for name, p in (("min_ms", 0), ("p50_ms", 0.5), ("p95_ms", 0.95), ("p99_ms", 0.99), ("max_ms", 1))
        },
    }


def measure(binary, directory, targets, hz, seconds, flags=()):
    directory.mkdir(parents=True, exist_ok=False)
    controls = [f"pushEncoder.{group}.{n}" for group in range(1, 4) for n in range(1, 9)]
    mapping = {
        "version": 7,
        "entries": [
            {
                "control": {"section": "pushEncoder", "row": group, "index": n},
                "midi": {"kind": "controlChange", "channel": 0, "number": (group - 1) * 8 + n},
                "ringMode": "12dot",
            }
            for group in range(1, 4)
            for n in range(1, 9)
        ],
    }
    map_path = directory / "TEST-ONLY-map.json"
    map_path.write_text(json.dumps(mapping))
    commands = directory / "TEST-ONLY-commands.json"
    commands.write_text("[]")
    report, timing = directory / "device.json", directory / "device-timing.jsonl"
    tokens = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
    env = {k: v for k, v in os.environ.items() if k != "BCR_PROVIDER_TOKEN"}
    env.update(
        BCR_PROVIDER_TEST_HARDWARE="1",
        BCR_PROVIDER_TEST_HARDWARE_SCRIPT=str(commands),
        BCR_PROVIDER_TEST_HARDWARE_REPORT=str(report),
        BCR_PROVIDER_TEST_HARDWARE_TIMING_JSONL=str(timing),
    )
    rows, input_reads, polls, errors = [], [], [], []
    arguments = [
        str(binary),
        "--source",
        "hardware",
        "--hardware-profile",
        "--hardware-output",
        "write",
        "--allow-surface-feedback",
        "--hardware-map",
        str(map_path),
        "--port",
        "0",
        "--surface-instance-id",
        "load",
        "--surface-client-tokens-stdin",
        *flags,
    ]
    with (directory / "stderr.log").open("w") as stderr:
        process = subprocess.Popen(
            arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, env=env, cwd="/tmp", text=True
        )
        try:
            process.stdin.write(json.dumps(tokens))
            process.stdin.close()
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            if not selector.select(10):
                raise RuntimeError("Provider did not become ready")
            ready = json.loads(process.stdout.readline())
            if not ready.get("test_only_hardware_double"):
                raise RuntimeError("Measurement requires explicit fake device")
            display = Client(ready["url"], tokens["display"], "load", accepted_sources=("hardware",))
            reader = Client(ready["url"], tokens["operator"], "load", accepted_sources=("hardware",))
            for role, client in (("display", display), ("reader", reader)):
                original_open = client.opener.open

                def diagnosed_open(*arguments, _open=original_open, _role=role, **keywords):
                    try:
                        return _open(*arguments, **keywords)
                    except Exception as error:
                        reason = getattr(error, "reason", None)
                        with (directory / (_role + "-transport-causes.jsonl")).open("a") as cause_log:
                            cause_log.write(
                                json.dumps(
                                    {
                                        "at": time.monotonic(),
                                        "exception": type(error).__name__,
                                        "reason_type": type(reason).__name__,
                                        "errno": getattr(reason, "errno", None),
                                        "host_exit": process.poll(),
                                    }
                                )
                                + "\n"
                            )
                        raise

                client.opener.open = diagnosed_open
                client.discover(versions=("1.4",))
            start = time.monotonic()
            end = start + seconds
            producer_finished = threading.Event()

            def inject():
                steps = []
                try:
                    index = 0
                    while start + index / 5 < end:
                        deadline = start + index / 5
                        time.sleep(max(0, deadline - time.monotonic()))
                        steps.append({"operation": "input", "cc": 1, "value": 64 + index % 64})
                        temporary = commands.with_suffix(".tmp")
                        temporary.write_text(json.dumps(steps))
                        temporary.replace(commands)
                        index += 1
                except Exception as error:
                    errors.append("input producer: " + type(error).__name__)
                finally:
                    producer_finished.set()

            def read_events():
                cursor = "0"
                try:
                    with (directory / "events.jsonl").open("w") as event_log:
                        while time.monotonic() < end + 0.25 or not producer_finished.is_set():
                            began = time.monotonic()
                            page = reader.call(
                                "surface_control_events",
                                {
                                    "instance_id": "load",
                                    "epoch": reader.expected["epoch"],
                                    "after_sequence": cursor,
                                    "limit": 1024,
                                },
                            )
                            received = time.monotonic()
                            polls.append(
                                {
                                    "start": began,
                                    "end": received,
                                    "after": cursor,
                                    "latest": page["latest_sequence"],
                                    "event_count": len(page["events"]),
                                }
                            )
                            for event in page["events"]:
                                event_log.write(json.dumps({"received_at": received, "event": event}) + "\n")
                                if event["kind"] == "input":
                                    input_reads.append({"received_at": received, "event": event})
                            cursor = page["latest_sequence"]
                            time.sleep(max(0, 0.025 - (time.monotonic() - began)))
                except Exception as error:
                    errors.append("event reader: " + getattr(error, "code", type(error).__name__))

            threads = [threading.Thread(target=inject), threading.Thread(target=read_events)]
            for thread in threads:
                thread.start()
            with (directory / "requests.jsonl").open("w") as request_log:
                for frame in range(int(hz * seconds)) if targets else ():
                    time.sleep(max(0, start + frame / hz - time.monotonic()))
                    for index, control in enumerate(controls[:targets]):
                        value = (frame + index) % 64
                        began = time.monotonic()
                        try:
                            event = display.feedback(control, "value", value)
                            row = {
                                "outcome": "accepted",
                                "disposition": event["disposition"],
                                "event_sequence": event["sequence"],
                            }
                        except SurfaceError as error:
                            row = {"outcome": error.code}
                        row.update(
                            control_id=control,
                            cc=index + 1,
                            value=value,
                            start=began,
                            end=time.monotonic(),
                            frame=frame,
                        )
                        rows.append(row)
                        request_log.write(json.dumps(row) + "\n")
            for thread in threads:
                thread.join(timeout=max(10, seconds + 5))
            if any(thread.is_alive() for thread in threads):
                raise RuntimeError("Owned measurement worker did not finish")
            (directory / "polls.json").write_text(json.dumps(polls, indent=2) + "\n")
            (directory / "inputs-read.json").write_text(json.dumps(input_reads, indent=2) + "\n")
            snapshot = reader.snapshot()
        finally:
            process.terminate()
            process.wait(timeout=5)
            process.stdout.close()
    device = [json.loads(line) for line in timing.read_text().splitlines()]
    sends = defaultdict(deque)
    for event in device:
        if event["kind"] == "send" and event["bytes"][2] < 64:
            sends[(event["bytes"][1], event["bytes"][2])].append(event["at"])
    latencies, unmatched, input_refresh_sends = [], 0, 0
    matches, ambiguous = [], 0
    accepted = [row for row in rows if row["outcome"] == "accepted"]
    for row in accepted:
        queue = sends[(row["cc"], row["value"])]
        while queue and queue[0] < row["start"]:
            queue.popleft()
            input_refresh_sends += 1
        candidates = []
        while queue and queue[0] <= row["end"]:
            candidates.append(queue.popleft())
        matches.append({"request": row, "matching_fake_times": candidates})
        if candidates:
            ambiguous += len(candidates) > 1
            input_refresh_sends += len(candidates) - 1
            # Include the conservative upper end when an input refresh shares this request window.
            delay = candidates[-1] - row["start"]
            if not 0 <= delay < 10:
                errors.append("monotonic clock domains differ")
            latencies.append(delay * 1000)
        else:
            unmatched += 1
    input_refresh_sends += sum(len(q) for q in sends.values())
    generated_inputs = [r for r in device if r["kind"] == "input"]
    if input_refresh_sends > len(generated_inputs):
        errors.append("unexplained extra display sends")
    input_delay = [(r["received_at"] - r["event"]["time"]) * 1000 for r in input_reads]
    if len(input_reads) != len(generated_inputs):
        errors.append("input event count differs from fake-device generation")
    generated_delay = []
    if len(input_reads) == len(generated_inputs):
        for observed, generated in zip(input_reads, generated_inputs):
            if observed["event"]["value"] != generated["value"]:
                errors.append("input ordering or value mismatch")
            generated_delay.append((observed["received_at"] - generated["at"]) * 1000)
    with (directory / "request-send-matches.jsonl").open("w") as match_log:
        for item in matches:
            match_log.write(json.dumps(item) + "\n")
    summary = {
        "targets": targets,
        "hz": hz,
        "requested_seconds": seconds,
        "elapsed_seconds": time.monotonic() - start,
        "requests": len(rows),
        "accepted": len(accepted),
        "quota_rejected": sum(r["outcome"] in ("rate_limited", "invalid_argument") for r in rows),
        "rejections_by_code": dict(Counter(r["outcome"] for r in rows if r["outcome"] != "accepted")),
        "ambiguous_request_send_windows": ambiguous,
        "other_rejections": sorted(
            {r["outcome"] for r in rows if r["outcome"] not in ("accepted", "rate_limited", "invalid_argument")}
        ),
        "ignored": sum(r.get("disposition") == "ignored" for r in accepted),
        "coalesced_or_missing_send": unmatched,
        "input_overlay_refresh_sends": input_refresh_sends,
        "request_to_fake_ms": distribution(latencies),
        "request_rtt_ms": distribution([(r["end"] - r["start"]) * 1000 for r in rows]),
        "input_events_generated": len(generated_inputs),
        "input_events_read": len(input_reads),
        "input_event_to_reader_ms": distribution(input_delay),
        "fake_input_to_reader_ms": distribution(generated_delay),
        "quota_error_semantics": "Legacy hardware aggregate exhaustion returns invalid_argument; unchanged. Requests use validated target/range/schema.",
        "event_poll_rtt_ms": distribution([(r["end"] - r["start"]) * 1000 for r in polls]),
        "final_sequence": snapshot["latest_sequence"],
        "flags": list(flags),
        "errors": errors,
        "scope": "Debug fake device only; no USB MIDI reliability or physical qualification",
    }
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if errors or summary["other_rejections"]:
        raise RuntimeError("Measurement integrity failed; inspect raw evidence")
    print(json.dumps({"completed": directory.name, "accepted": len(accepted), "errors": errors}), flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--provider-flag", action="append", default=[])
    parser.add_argument("--workers", type=int, default=1)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    conditions = [(0, 5), *[(n, hz) for n in (8, 16, 24) for hz in (5, 10)]]
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        jobs = [
            pool.submit(
                measure,
                args.binary.resolve(),
                args.output.resolve() / f"{n}x{hz}",
                n,
                hz,
                args.seconds,
                args.provider_flag,
            )
            for n, hz in conditions
        ]
        summaries = [job.result() for job in jobs]
    (args.output / "summary.json").write_text(
        json.dumps({"isolated_concurrent_processes": args.workers, "conditions": summaries}, indent=2) + "\n"
    )
    print(json.dumps(summaries))


if __name__ == "__main__":
    main()
