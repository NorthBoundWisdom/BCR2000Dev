#!/usr/bin/env python3
"""Verify all 56 learned absolute CC encoders through running App MCP and device snapshots.

Writes only through SurfaceSession via MCP; restores the initial parameter values.
Requires BCR_MCP_TOKEN in the environment. Raw identities stay in private local reports.
"""

import argparse
import os
from pathlib import Path
import time

from bcr_protocol import identity_info
from diagnostic_io import write_json
from macos_bcr_roundtrip import MacBCR
from mcp_smoke import Client
from midi_feedback_probe import resolve


def verify(client, backend, report_path):
    status = client.call("get_status")
    if status["source"] != "hardware" or not status["hardwareConnection"]["connected"]:
        raise ValueError("App must be connected in hardware mode")
    if status["motionSafety"]["status"] != "disconnected":
        raise ValueError("Stop external output before testing encoder feedback")
    controls = [c for c in client.call("list_controls") if c["control"]["section"] in ("pushEncoder", "encoder")]
    parameters = {p["id"]: p for p in client.call("list_parameters")}
    if len(controls) != 56:
        raise ValueError("Expected all 56 encoders")
    entries, identities, ids = [], set(), set()
    for control in controls:
        binding, assignment = control.get("binding"), control.get("assignment")
        if not binding or binding["kind"] != "controlChange" or not assignment:
            raise ValueError("Each encoder must have a learned ordinary CC identity and assignment")
        if assignment["encoderMode"] != "absolute" or assignment["inverted"]:
            raise ValueError("Only non-inverted absolute encoders are supported")
        identifier = assignment["target"].get("parameter", {}).get("_0")
        parameter = parameters.get(identifier)
        if not parameter or not parameter["writable"] or parameter["kind"] != "continuous" or parameter.get("step"):
            raise ValueError("Expected writable continuous parameters without step snapping")
        identity = (binding["channel"] + 1, binding["number"])
        if identity in identities or identifier in ids:
            raise ValueError("Independent encoder identities/parameters required for this test")
        identities.add(identity)
        ids.add(identifier)
        entries.append((identity, parameter))
    original = [{"id": p["id"], "value": p["value"]} for _, p in entries]
    report = {"encoderCount": 56, "patterns": [], "restored": False}
    try:
        backend.open(resolve(backend.ports(True), None, "input"), resolve(backend.ports(False), None, "output"))
        _, frames = backend.query(1, 1)
        if len([f for f in frames if identity_info(f) is not None]) != 1:
            raise ValueError("Expected one live BCR2000 identity")
        for phase in range(5):
            expected = {identity: (index * 17 + phase * 23) % 128 for index, (identity, _) in enumerate(entries)}
            values = [
                {"id": p["id"], "value": p["minimum"] + (p["maximum"] - p["minimum"]) * expected[identity] / 127}
                for identity, p in entries
            ]
            client.call("set_parameters", {"values": values})
            time.sleep(0.25)
            messages, _ = backend.query(0x43, 1)
            actual = {}
            for message in messages:
                key = (message.channel, message.controller)
                if key in actual and actual[key] != message.value:
                    raise ValueError("Device snapshot changed during verification")
                actual[key] = message.value
            matched = sum(actual.get(key) == value for key, value in expected.items())
            report["patterns"].append({"pattern": phase + 1, "matched": matched, "expected": 56})
            print(f"Pattern {phase + 1}: {matched}/56 App → BCR2000 → readback", flush=True)
            if matched != 56 or backend.events.dropped:
                raise ValueError("Encoder readback mismatch or dropped MIDI input")
    finally:
        try:
            client.call("set_parameters", {"values": original})
            time.sleep(0.25)
            messages, _ = backend.query(0x43, 1)
            actual = {(m.channel, m.controller): m.value for m in messages}
            expected = {
                identity: round((p["value"] - p["minimum"]) * 127 / (p["maximum"] - p["minimum"]))
                for identity, p in entries
            }
            report["restored"] = all(actual.get(key) == value for key, value in expected.items())
            report["inputDropped"] = backend.events.dropped
            if not report["restored"]:
                raise ValueError("Restored values did not match device readback")
        finally:
            try:
                backend.close()
            finally:
                write_json(report_path, report)
    if client.call("get_status")["droppedFeedbackCount"]:
        raise ValueError("App reported dropped feedback")
    print("All 280 readbacks passed; initial parameter values restored and confirmed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8787/mcp")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    token = os.environ.get("BCR_MCP_TOKEN")
    if not token:
        parser.error("Set BCR_MCP_TOKEN; never pass tokens on the command line")
    verify(Client(args.url, token), MacBCR(), args.report)
