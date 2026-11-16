#!/usr/bin/env python3
"""Run the unchanged workflow suite with per-case wall-time evidence."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


class TimedResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.durations = []

    def startTest(self, test):
        self.started = time.perf_counter()
        super().startTest(test)

    def stopTest(self, test):
        self.durations.append({"test": test.id(), "seconds": time.perf_counter() - self.started})
        super().stopTest(test)


def main():
    suite = unittest.defaultTestLoader.discover(str(ROOT / "Tests/BuildWorkflowTests"))
    result = unittest.TextTestRunner(verbosity=2, resultclass=TimedResult).run(suite)
    records = sorted(result.durations, key=lambda row: -row["seconds"])
    output = ROOT / "build/ci-verification/tests/python-case-times.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(records, indent=2) + "\n")
    print("Slowest workflow cases:")
    for row in records[:20]:
        print(f"{row['seconds']:.3f}s {row['test']}")
    return int(not result.wasSuccessful())


if __name__ == "__main__":
    raise SystemExit(main())
