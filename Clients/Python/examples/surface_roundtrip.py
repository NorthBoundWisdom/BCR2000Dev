#!/usr/bin/env python3
"""Minimal generic simulation consumer using only a pinned public delivery, no Pipe."""

import argparse
import json
from pathlib import Path

from pipe_surface_trial import delivery, private_token, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--input-parameter", default="simulation.arm")
    parser.add_argument("--feedback-parameter", default="simulation.progress")
    args = parser.parse_args()
    sdk, _ = delivery(args.artifact.resolve(), args.manifest_sha256)
    client = sdk.Client(args.url, private_token(args.token_file), args.instance_id)
    discovery = client.discover()
    rows = discovery["profile"]["controls"]

    def mapped(identifier):
        found = [row for row in rows if (row.get("mapping") or {}).get("id") == identifier]
        require(len(found) == 1, "one explicit mapping is required")
        return found[0]

    source, display = mapped(args.input_parameter), mapped(args.feedback_parameter)
    require(source["encoding"] == "scalar" and "value" in display["feedback_kinds"], "scalar/value capability required")
    before = client.snapshot()
    raw = source["range"]["maximum"]
    event = client.input(source["id"], source["encoding"], raw)
    observed = client.snapshot()
    value = (display.get("feedback_range") or display["range"])["maximum"]
    feedback = client.feedback(display["id"], "value", value)
    after = client.snapshot()
    require(observed["inputs"] == after["inputs"], "feedback changed an input")
    print(
        json.dumps(
            {
                "source": "simulation",
                "expected": client.expected,
                "before_sequence": before["latest_sequence"],
                "input": event,
                "feedback": feedback,
                "after_sequence": after["latest_sequence"],
                "passed": True,
            }
        )
    )


if __name__ == "__main__":
    main()
