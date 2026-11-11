"""Shared guarded identity/snapshot/CC verification for native MIDI adapters."""

import json
import sys
import time

from bcr_protocol import identity_info, snapshot_values
from diagnostic_io import write_json
from midi_feedback_probe import CC, resolve


def run_roundtrip(args, backend_factory):
    backend = backend_factory()
    report = {
        "schemaVersion": 1,
        "platform": sys.platform,
        "identity": None,
        "snapshotCCCount": 0,
        "writes": [],
        "visualLED": "not observed remotely",
    }
    original = None
    write_attempted = False
    failure = None
    try:
        inputs, outputs = backend.ports(True), backend.ports(False)
        print(
            json.dumps({"inputs": [p.__dict__ for p in inputs], "outputs": [p.__dict__ for p in outputs]}), flush=True
        )
        source, destination = resolve(inputs, args.input, "input"), resolve(outputs, args.output, "output")
        if "bcr2000" not in source.name.lower() or "bcr2000" not in destination.name.lower():
            raise ValueError("Only explicitly named BCR2000 endpoints are supported")
        report.update(input=source.name, output=destination.name)
        backend.open(source, destination)
        _, replies = backend.query(1, args.wait)
        identities = [info for frame in replies if (info := identity_info(frame)) is not None]
        report["identity"] = identities[0] if identities else None
        baseline, _ = backend.query(0x43, args.wait)
        report["snapshotCCCount"] = len(baseline)
        report["inputDropped"] = backend.events.dropped
        if backend.events.dropped:
            raise RuntimeError("Baseline input overflow; no CC write attempted")
        print(json.dumps({"identity": report["identity"], "snapshotCCCount": len(baseline)}), flush=True)
        if args.test_cc is None:
            report["testStatus"] = "read_only_complete"
            return report
        if args.test_cc in {0, 6, 32, 38, 96, 97, 98, 99, 100, 101} or not 1 <= args.test_cc < 120:
            raise ValueError("Choose a known ordinary absolute CC encoder")
        if report["identity"] is None:
            raise RuntimeError("No device identity response; no CC write attempted")
        value = snapshot_values(baseline, args.channel, args.test_cc)
        if value is None:
            raise RuntimeError("Target absent or snapshot unverified; no CC write attempted")
        if getattr(args, "expected_identity", None) and report["identity"]["identity"] != args.expected_identity:
            raise RuntimeError("Device identity does not match the expected baseline")
        original = CC(args.channel, args.test_cc, value)
        report["target"] = {"channel": args.channel, "controller": args.test_cc}
        report["baselineValue"] = value
        report["testStatus"] = "baseline_captured_before_write"
        if args.report:
            write_json(args.report, report)
        for target in (0, 32, 64, 96, 127):
            write_attempted = True
            backend.send(CC(args.channel, args.test_cc, target))
            pre_snapshot = backend.collect(0.25)
            messages, _ = backend.query(0x43, args.wait)
            observed = snapshot_values(messages, args.channel, args.test_cc)
            result = {
                "requested": target,
                "observed": observed,
                "matches": observed == target,
                "echoCandidatesWithin250ms": sum(
                    m.channel == args.channel and m.controller == args.test_cc for m in pre_snapshot
                ),
            }
            report["writes"].append(result)
            print(json.dumps(result), flush=True)
        report["inputDropped"] = backend.events.dropped
        if backend.events.dropped:
            raise RuntimeError("Input overflow; roundtrip result is incomplete")
        report["valueRoundtripPassed"] = all(item["matches"] for item in report["writes"])
        report["testStatus"] = (
            "value_roundtrip_verified" if report["valueRoundtripPassed"] else "value_roundtrip_failed"
        )
        return report
    except BaseException as error:
        failure = error
        report["testStatus"] = "error"
        report["error"] = {"type": type(error).__name__, "message": str(error)}
        raise
    finally:
        if original is not None and write_attempted:
            final = CC(original.channel, original.controller, 127) if args.hold_max else original
            try:
                backend.send(final)
                report["finalRequested"] = final.value
                time.sleep(0.1)
                snapshot, _ = backend.query(0x43, args.wait)
                report["finalObserved"] = snapshot_values(snapshot, final.channel, final.controller)
            except Exception as error:
                report["finalError"] = str(error)
        try:
            backend.close()
            report["cleanup"] = "closed"
        except Exception as error:
            report["cleanupError"] = str(error)
            print("CLEANUP ERROR: " + str(error), file=sys.stderr)
            if failure is None:
                raise
        finally:
            if args.report:
                write_json(args.report, report)
