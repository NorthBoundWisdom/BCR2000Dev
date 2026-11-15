"""Private executable fixture: a SwiftPM-like parallel `swift test` that writes an xunit report."""

import json
from pathlib import Path
import sys
import time
from xml.sax.saxutils import quoteattr


def main():
    root = Path(__file__).resolve().parent
    options = json.loads((root / "fake-runner.json").read_text())
    arguments = sys.argv[1:]
    with (root / "fake-calls.jsonl").open("a") as calls:
        calls.write(json.dumps(arguments) + "\n")
    report = Path(arguments[arguments.index("--xunit-output") + 1])
    cases = options["cases"]
    rows, failures = [], 0
    for number, identifier in enumerate(cases, 1):
        print(f"[{number}/{len(cases)}] Testing {identifier}", flush=True)
        if identifier == options.get("hang_case"):
            time.sleep(3600)
        owner, method = identifier.split("/", 1)
        failed = owner.split(".", 1)[0] == options.get("fail_module") and failures == 0
        skipped = identifier == options.get("skip_case")
        failures += int(failed)
        body = "<failure message='fixture'/>" if failed else "<skipped/>" if skipped else ""
        rows.append(f"<testcase classname={quoteattr(owner)} name={quoteattr(method)} time='0.001'>{body}</testcase>")
    if not options.get("omit_report"):
        report.write_text(
            f"<?xml version='1.0' encoding='UTF-8'?><testsuites><testsuite name='TestResults' tests='{len(cases)}' "
            f"failures='{failures}'>{''.join(rows)}</testsuite></testsuites>"
        )
    raise SystemExit(options.get("exit_code", 1 if failures else 0))


if __name__ == "__main__":
    main()
