#!/usr/bin/env python3
"""Check handwritten learned MIDI identities against the exact packaging map; no device I/O."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = ("F_PIPE_HANDOFF.md", "F_CANDIDATE_ATTENDED.md")


def check(hardware_map: Path, docs: Path = ROOT / "docs") -> dict:
    entries = json.loads(hardware_map.read_text())["entries"]
    addresses = {
        f"{entry['control']['section']}.{entry['control']['row']}.{entry['control']['index']}": entry["midi"]
        for entry in entries
    }
    checked = []
    for name in DOCUMENTS:
        content = (docs / name).read_text()
        for line in content.splitlines():
            if not re.search(r"\bCC\d+", line):
                continue
            control = re.search(r"`((?:pushEncoder|button)\.\d+\.\d+)`", line)
            if not control or not line.startswith("|"):
                raise ValueError(f"{name}: learned address outside a control-ID table row")
            identifier = control[1]
            midi = addresses[identifier]
            numbers = re.findall(r"\bCC(\d+)", line)
            if len(numbers) != 1:
                raise ValueError(f"{name}: expected one learned MIDI identity per control row")
            number = int(numbers[0])
            channel = re.search(r"\bchannel (\d+)", line)
            if (
                midi["kind"] != "controlChange"
                or number != midi["number"]
                or (channel and int(channel[1]) != midi["channel"] + 1)
            ):
                raise ValueError(f"{name}: {identifier} learned MIDI identity differs from map")
            checked.append({"document": name, "control_id": identifier, "midi": midi})
    if len(checked) != 8:
        raise ValueError("Expected all four flow and four candidate rows")
    return {"passed_count": len(checked), "failed_count": 0, "skipped_count": 0, "addresses": checked}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hardware-map", type=Path, required=True)
    parser.add_argument("--docs", type=Path, default=ROOT / "docs")
    args = parser.parse_args()
    print(json.dumps(check(args.hardware_map, args.docs), indent=2))


if __name__ == "__main__":
    main()
