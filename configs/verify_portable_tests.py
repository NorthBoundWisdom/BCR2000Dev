#!/usr/bin/env python3
"""Reconcile stock SwiftPM XCTest output against discovery on Darwin and corelibs XCTest."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from configs.xctest_runner import inventory  # noqa: E402

MODULES = ["BCRAgentCoreTests", "BCRPluginHostTests", "BCRProviderDomainTests", "BCRProviderAdapterTests"]
MAC = re.compile(r"Test Case '-\[([^ ]+) ([^]]+)\]' (started|passed|failed|skipped)(?:\.| \(.*)")
CORELIBS = re.compile(r"Test Case '([^']+)' (started|passed|failed|skipped)(?: at .*| \(.*|\.)")


def verify(cases, output):
    aliases = {}
    for case in cases:
        owner, method = case.split("/", 1)
        short = owner.rsplit(".", 1)[-1] + "/" + method
        for key in (case, short):
            if key in aliases and aliases[key] != case:
                raise RuntimeError("Ambiguous XCTest name: " + key)
            aliases[key] = case
    started, completed, statuses = Counter(), Counter(), Counter()
    for line in output.splitlines():
        if match := MAC.fullmatch(line):
            owner, method, status = match.groups()
            key = owner + "/" + method
        elif match := CORELIBS.fullmatch(line):
            name, status = match.groups()
            owner, _, method = name.rpartition(".")
            key = owner + "/" + method
        else:
            continue
        if key not in aliases:
            raise RuntimeError("Unexpected XCTest result: " + key)
        case = aliases[key]
        if status == "started":
            started[case] += 1
        else:
            completed[case] += 1
            statuses[status] += 1
    expected = Counter(cases)
    if started != expected or completed != expected:
        raise RuntimeError(
            f"Portable inventory mismatch: discovered={len(cases)}, started={sum(started.values())}, completed={sum(completed.values())}"
        )
    if statuses["failed"] or statuses["skipped"]:
        raise RuntimeError(f"Portable failures/skips: {dict(statuses)}")
    return {"tests": len(cases), "failures": statuses["failed"], "skipped": statuses["skipped"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    cases = inventory(args.inventory.read_text(), MODULES)
    result = verify(cases, args.log.read_text())
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
