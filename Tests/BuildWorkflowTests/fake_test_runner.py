"""Private executable fixture: a SwiftPM-like `swift test` that prints XCTest output for its cases."""

import json
from pathlib import Path
import sys
import time


def emit(bundle, entries, options):
    print(f"Test Suite '{bundle}' started at fixture.")
    failures = 0
    for identifier in entries:
        owner, method = identifier.split("/", 1)
        name = f"-[{owner} {method}]"
        print(f"Test Case '{name}' started.", flush=True)
        if identifier == options.get("hang_case"):
            time.sleep(3600)
        failed = owner.split(".", 1)[0] == options.get("fail_module") and failures == 0
        print(f"Test Case '{name}' {'failed' if failed else 'passed'} (0.001 seconds).")
        failures += int(failed)
    print(f"Test Suite '{bundle}' {'failed' if failures else 'passed'} at fixture.")
    print(f"Executed {len(entries)} tests, with {failures} failures (0 unexpected) in 0.001 seconds")
    return failures


def main():
    root = Path(__file__).resolve().parent
    options = json.loads((root / "fake-runner.json").read_text())
    with (root / "fake-calls.jsonl").open("a") as calls:
        calls.write(json.dumps(sys.argv[1:]) + "\n")
    cases = options["cases"]
    failures = 0
    if options.get("layout", "split") == "split":
        modules = dict.fromkeys(case.split(".", 1)[0] for case in cases)
        for module in modules:
            failures += emit(module + ".xctest", [case for case in cases if case.startswith(module + ".")], options)
    else:
        failures = emit(options.get("package", "Fixture") + "PackageTests.xctest", cases, options)
    raise SystemExit(options.get("exit_code", 1 if failures else 0))


if __name__ == "__main__":
    main()
