"""Private executable fixture used by test_test_summary; not a production runner."""

import json
import os
from pathlib import Path
import re
import sys


def main():
    root = Path(__file__).resolve().parent
    options = json.loads((root / "fake-runner.json").read_text())
    action = "list" if "list" in sys.argv[1:] else "run"
    with (root / "fake-calls.jsonl").open("a") as stream:
        stream.write(json.dumps({"action": action, "pid": os.getpid(), "arguments": sys.argv[1:]}) + "\n")
    cases = options["cases"]
    if action == "list":
        print("\n".join(options.get("inventory", cases)))
        return
    pattern = sys.argv[sys.argv.index("--filter") + 1]
    selected = cases if options.get("ignore_filter") else [case for case in cases if re.search(pattern, case)]
    selected = [case for case in selected if case != options.get("omit")]
    if options.get("duplicate_case") in selected:
        selected.append(options["duplicate_case"])
    if options.get("unknown_case"):
        selected.append("Unknown.Spurious/testExtra")
    if options.get("empty"):
        selected = []
    modules = list(dict.fromkeys(case.split(".", 1)[0] for case in [*cases, *selected]))

    def emit(bundle, entries):
        print(f"Test Suite '{bundle}' started at fixture.")
        failures = 0
        for identifier in entries:
            owner, method = identifier.split("/", 1)
            name = f"-[{owner} {method}]"
            failed = owner.split(".", 1)[0] == options.get("fail_module") and failures == 0
            print(f"Test Case '{name}' started.")
            print(f"Test Case '{name}' {'failed' if failed else 'passed'} (0.001 seconds).")
            failures += int(failed)
        print(f"Test Suite '{bundle}' {'failed' if failures else 'passed'} at fixture.")
        print(f"Executed {len(entries)} tests, with {failures} failures (0 unexpected) in 0.001 seconds")

    if options.get("layout", "aggregate") == "split":
        for module in modules:
            emit(module + ".xctest", [case for case in selected if case.startswith(module + ".")])
    else:
        bundle = (
            "Selected tests"
            if options.get("layout") == "selected"
            else options.get("package", "Fixture") + "PackageTests.xctest"
        )
        emit(bundle, selected)
    raise SystemExit(options.get("exit_code", 0))


if __name__ == "__main__":
    main()
