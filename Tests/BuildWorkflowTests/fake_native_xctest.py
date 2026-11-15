"""Private native-process fixture for discovery/accounting/crash/timeout runner tests."""

import json
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parent
options = json.loads((root / "fixture.json").read_text())
classes = sys.argv[sys.argv.index("-XCTest") + 1].split(",")
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(classes) + "\n")
if options.get("hang"):
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3600)"])
    with (root / "children.jsonl").open("a") as log:
        log.write(str(child.pid) + "\n")
    time.sleep(3600)
for identifier in options["cases"] + options.get("extra", []):
    owner, method = identifier.split("/")
    if owner not in classes:
        continue
    if identifier != options.get("omit_start"):
        print(f"Test Case '-[{owner} {method}]' started.", flush=True)
    if identifier == options.get("omit_finish"):
        continue
    status = options.get("status", "passed")
    if status == "failed":
        print("fixture.swift:1: error: original assertion failed", flush=True)
    for _ in range(2 if options.get("duplicate") else 1):
        print(f"Test Case '-[{owner} {method}]' {status} (0.003 seconds).", flush=True)
sys.exit(options.get("exit_code", 0))
