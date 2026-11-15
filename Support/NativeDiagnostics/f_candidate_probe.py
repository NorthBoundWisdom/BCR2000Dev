#!/usr/bin/env python3
"""Attended candidate probe for an already-owned provider; default action is read-only."""

import argparse
import json
from pathlib import Path
import stat
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--provider-sdk", type=Path)
    parser.add_argument("--url", required=True)
    parser.add_argument("--instance", required=True)
    parser.add_argument("--mapping-revision", required=True)
    parser.add_argument("--action", choices=("snapshot", "edges", "raw-edges", "display"), default="snapshot")
    parser.add_argument("--control", choices=("button.1.1", "button.1.2"), default="button.1.1")
    parser.add_argument("--value", choices=("on", "off"))
    parser.add_argument("--confirm-attended-display", action="store_true")
    args = parser.parse_args()
    try:
        if not stat.S_ISFIFO(__import__("os").fstat(sys.stdin.fileno()).st_mode):
            raise ValueError("private pipe required")
        token = sys.stdin.read(65)
        if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
            raise ValueError("invalid credential")
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(args.sdk))
        from surface_control import Client

        client = Client(args.url, token, args.instance, accepted_sources=("hardware",))
        discovery = client.discover(profiles=("bcr2000.hardware",), versions=("1.4",), profile_versions=("1.4",))
        if discovery["expected"]["mapping_revision"] != args.mapping_revision:
            raise ValueError("mapping mismatch")
        snapshot = client.snapshot()
        expected = dict(client.expected)
        if args.action == "snapshot":
            print(
                json.dumps(
                    {
                        "passed": True,
                        "connected": snapshot["link"]["state"] == "connected",
                        "unknown_input_count": len(client.profile["controls"]) - len(snapshot["inputs"]),
                        "physical_qualification": False,
                    }
                )
            )
            return
        if snapshot["link"]["state"] != "connected":
            raise ValueError("disconnected")
        if args.action in ("raw-edges", "display"):
            provider_sdk = args.provider_sdk or args.sdk.parent / "bcr-provider-sdk-1.0.0.zip"
            sys.path.insert(0, str(provider_sdk))
            from bcr_provider import Client as ProviderClient

            legacy = ProviderClient(args.url, token)
            baseline = legacy.call("console_events", {"schema_version": 1, "limit": 256})
            raw_cursor = {
                "schema_version": 1,
                "generation": baseline["generation"],
                "after_sequence": baseline["latest_sequence"],
                "limit": 256,
            }
            cc = 67 if args.control == "button.1.1" else 68
        if args.action == "raw-edges":
            print(json.dumps({"event": "awaiting_new_raw_edges", "control": args.control}), flush=True)
            raw_values = []
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                batch = legacy.call("console_events", raw_cursor)
                if batch["generation"] != baseline["generation"] or batch["reset"] or batch["dropped"]:
                    raise ValueError("raw cursor invalid")
                for event in batch["events"]:
                    payload = event["payload"]
                    if event["kind"] == "control.raw" and payload.get("midi") == {
                        "kind": "controlChange",
                        "channel": 0,
                        "number": cc,
                    }:
                        if event["source"] != "hardware":
                            raise ValueError("wrong raw source")
                        raw_values.append(payload["raw_value"])
                raw_cursor["after_sequence"] = batch["latest_sequence"]
                if raw_values == [127, 0]:
                    print(json.dumps({"passed": True, "raw_press_release": [127, 0], "physical_qualification": False}))
                    return
                if len(raw_values) >= 2:
                    raise ValueError("raw edges differ")
                time.sleep(0.05)
            raise ValueError("raw edge timeout")
        if args.action == "display":
            if not (args.confirm_attended_display and args.value):
                raise ValueError("explicit attended display confirmation required")
            before_input = snapshot["latest_input_sequence"]
            client.feedback(args.control, "indicator", args.value)
            if client.snapshot()["latest_input_sequence"] != before_input:
                raise ValueError("display became input")
            batch = legacy.call("console_events", raw_cursor)
            sent = [event for event in batch["events"] if event["kind"] == "feedback.sent"]
            if batch["generation"] != baseline["generation"] or batch["reset"] or len(sent) != 1:
                raise ValueError("display output count differs")
            payload = sent[0]["payload"]
            if payload.get("midi") != {"kind": "controlChange", "channel": 0, "number": cc} or payload["raw_value"] != (
                127 if args.value == "on" else 0
            ):
                raise ValueError("display address/value differs")
            print(
                json.dumps(
                    {
                        "passed": True,
                        "transport_accepted": True,
                        "physical_observation_required": True,
                        "physical_qualification": False,
                    }
                )
            )
            return
        after = snapshot["latest_sequence"]
        observed = []
        print(json.dumps({"event": "awaiting_new_edges", "control": args.control}), flush=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            page = client.call(
                "surface_control_events",
                {"instance_id": args.instance, "epoch": expected["epoch"], "after_sequence": after, "limit": 1024},
            )
            if page["expected"] != expected or page["link"]["state"] != "connected":
                raise ValueError("context changed")
            for event in page["events"]:
                if int(event["sequence"]) != int(after) + 1:
                    raise ValueError("event gap")
                after = event["sequence"]
                if event["control_id"] == args.control and event["kind"] == "input":
                    if (
                        event["source"] != "hardware"
                        or event["origin"] != "hardware"
                        or event["disposition"] != "accepted"
                    ):
                        raise ValueError("unqualified input")
                    observed.append(event["value"])
            if observed == [True, False]:
                print(json.dumps({"passed": True, "press_release_edges": 2, "physical_qualification": False}))
                return
            if len(observed) >= 2:
                raise ValueError("unexpected edges")
            time.sleep(0.05)
        raise ValueError("edge timeout")
    except Exception:
        print(json.dumps({"passed": False, "error": "candidate_probe_failed", "physical_qualification": False}))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
