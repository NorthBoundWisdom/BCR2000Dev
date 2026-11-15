#!/usr/bin/env python3
"""Summarize XCTest xunit durations (case time, not parallel wall time)."""

import argparse
import json
import re
import statistics
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


def summarize(paths):
    cases = []
    sources = set()
    for path in paths:
        root = ET.parse(path).getroot()
        sources.add(root.get("timing_source", "swiftpm-xunit"))
        for case in root.iter("testcase"):
            cases.append(
                {
                    "class": case.get("classname", ""),
                    "name": case.get("name", ""),
                    "seconds": float(case.get("time", "0")),
                    "failed": case.find("failure") is not None or case.find("error") is not None,
                    "skipped": case.find("skipped") is not None,
                }
            )
    result = aggregate(cases)
    result["measurement"] = next(iter(sources)) if len(sources) == 1 else "mixed-xunit"
    return result


def aggregate(cases):
    groups = defaultdict(list)
    for case in cases:
        groups[case["class"]].append(case["seconds"])
    classes = [
        {"class": name, "count": len(times), "seconds": sum(times), "median": statistics.median(times)}
        for name, times in groups.items()
    ]
    return {
        "count": len(cases),
        "seconds": sum(case["seconds"] for case in cases),
        "median": statistics.median(case["seconds"] for case in cases) if cases else 0,
        "failures": sum(case["failed"] for case in cases),
        "skipped": sum(case["skipped"] for case in cases),
        "classes": sorted(classes, key=lambda row: (-row["seconds"], row["class"])),
        "cases": sorted(cases, key=lambda row: (-row["seconds"], row["class"], row["name"])),
    }


def summarize_log(path):
    """XCTest's own per-case durations, excluding SwiftPM per-process startup overhead."""
    pattern = re.compile(r"Test Case '-\[([^ ]+) ([^]]+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)")
    cases = [
        {
            "class": group,
            "name": name,
            "seconds": float(seconds),
            "failed": status == "failed",
            "skipped": status == "skipped",
        }
        for group, name, status, seconds in pattern.findall(path.read_text(encoding="utf-8"))
    ]
    if not cases:
        raise ValueError("No completed XCTest cases in log")
    return aggregate(cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="*")
    parser.add_argument("--xctest-log", type=Path, help="read native XCTest durations instead of SwiftPM xunit")
    parser.add_argument("--json", type=Path, help="also write the complete summary as JSON")
    parser.add_argument("--limit", type=int, default=0, help="rows per table; 0 means all")
    args = parser.parse_args()
    if bool(args.reports) == bool(args.xctest_log):
        parser.error("provide xunit reports OR --xctest-log")
    result = summarize_log(args.xctest_log) if args.xctest_log else summarize(args.reports)
    if args.xctest_log:
        result["measurement"] = "xctest-inprocess"
    print(f"Measurement: {result['measurement']}")
    print(
        f"Cases: {result['count']}  Total: {result['seconds']:.3f}s  "
        f"Median: {result['median']:.3f}s  Failures: {result['failures']}  Skipped: {result['skipped']}"
    )
    print("\nSeconds   Count   Median  Class")
    for row in result["classes"][: args.limit or None]:
        print(f"{row['seconds']:8.3f} {row['count']:7} {row['median']:8.3f}  {row['class']}")
    print("\nSeconds  Case")
    for row in result["cases"][: args.limit or None]:
        print(f"{row['seconds']:8.3f}  {row['class']}.{row['name']}")
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
