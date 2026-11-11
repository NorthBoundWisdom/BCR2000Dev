#!/usr/bin/env python3
"""Published BCR diagnostic CLI 1.0: read-only native queries, coordinated by the provider.

Snapshot mode temporarily labels native receive traffic as diagnostic readback;
it never writes a device preset, replays a motion command, or changes a mapping.
"""

import argparse
import json
import os
from pathlib import Path
import sys

from bcr_protocol import identity_info
from diagnostic_io import write_json
from macos_bcr_roundtrip import MacBCR
from midi_feedback_probe import resolve

SDK = Path(__file__).resolve().parents[1] / "bcr-provider-sdk-1.0.0.zip"
if SDK.is_file():
    sys.path.insert(0, str(SDK))
from bcr_provider import Client  # noqa: E402 -- bootstrap the independently published SDK beside this tool


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("list", "snapshot"))
    parser.add_argument("--provider", help="Published loopback provider URL; credentials use BCR_PROVIDER_TOKEN")
    parser.add_argument("--expected-provider-id", default=os.environ.get("BCR_PROVIDER_ID"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    backend = MacBCR()
    client = None
    token = None
    report = None
    try:
        inputs, outputs = backend.ports(True), backend.ports(False)
        if args.mode == "list":
            report = {
                "schema_version": 1,
                "inputs": [p.__dict__ for p in inputs],
                "outputs": [p.__dict__ for p in outputs],
            }
        else:
            if not args.provider or not os.environ.get("BCR_PROVIDER_TOKEN"):
                parser.error("snapshot requires --provider and the environment credential")
            if not args.expected_provider_id:
                parser.error("snapshot requires --expected-provider-id (or BCR_PROVIDER_ID)")
            client = Client(
                args.provider, os.environ["BCR_PROVIDER_TOKEN"], expected_provider_id=args.expected_provider_id
            )
            capabilities = client.call("provider_capabilities")
            status = client.call("get_status")
            if status["source"] != "hardware" or not status["hardwareConnection"]["connected"]:
                raise ValueError("Snapshot requires the provider's connected hardware console")
            if status.get("pending_feedback_count", 0):
                raise ValueError("Wait for the provider's feedback queue to drain before a snapshot")
            token = client.call("console_diagnostics", {"operation": "begin"})["token"]
            backend.open(resolve(inputs, None, "input"), resolve(outputs, None, "output"))
            _, replies = backend.query(1, 1)
            identities = [identity_info(frame) for frame in replies if identity_info(frame) is not None]
            if len(identities) != 1:
                raise ValueError("Expected one physical BCR2000 identity")
            messages, _ = backend.query(0x43, 1)
            values = {}
            for message in messages:
                key = (message.channel, message.controller)
                if key in values and values[key] != message.value:
                    raise ValueError("Native snapshot changed during capture")
                values[key] = message.value
            if backend.events.dropped or not values:
                raise ValueError("Native snapshot was empty or input overflowed")
            report = {
                "schema_version": 1,
                "provider_id": capabilities["provider_id"],
                "source": "hardware",
                "origin": "readback",
                "identity": identities[0],
                "snapshot": [
                    {"channel": key[0], "number": key[1], "value": value} for key, value in sorted(values.items())
                ],
                "input_dropped": backend.events.dropped,
                "preset_written": False,
            }
            backend.collect(0.1)  # Finish draining this readback before restoring normal input classification.
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            write_json(args.output, report)
            print(json.dumps({"output_written": True, "mode": args.mode}))
        else:
            print(json.dumps(report, ensure_ascii=False))
        return 0
    finally:
        backend.close()
        if client is not None and token is not None:
            client.call("console_diagnostics", {"operation": "end", "token": token})


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        print(
            "Device diagnostic failed; inspect provider status. Diagnostic mode may require explicit recovery.",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
