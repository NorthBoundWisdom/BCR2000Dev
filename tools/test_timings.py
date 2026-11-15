#!/usr/bin/env python3
"""Summarize XCTest xunit durations (case time, not parallel wall time)."""

import argparse
import json
import statistics
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


def summarize(paths):
    cases = []
    for path in paths:
        for case in ET.parse(path).getroot().iter("testcase"):
            cases.append(
                {
                    "class": case.get("classname", ""),
                    "name": case.get("name", ""),
                    "seconds": float(case.get("time", "0")),
                    "failed": case.find("failure") is not None or case.find("error") is not None,
                    "skipped": case.find("skipped") is not None,
                }
            )
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="+")
    parser.add_argument("--json", type=Path, help="also write the complete summary as JSON")
    parser.add_argument("--limit", type=int, default=0, help="rows per table; 0 means all")
    args = parser.parse_args()
    result = summarize(args.reports)
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
