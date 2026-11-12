"""Private executable fixture: a SwiftPM-like serial worker driver with real child PIDs."""

import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET


def emit(bundle, entries, options):
    print(f"Test Suite '{bundle}' started at fixture.")
    failures = 0
    for identifier in entries:
        owner, method = identifier.split("/", 1)
        name = f"-[{owner} {method}]"
        failed = owner.split(".", 1)[0] == options.get("fail_module") and failures == 0
        skipped = identifier == options.get("skip_case")
        print(f"Test Case '{name}' started.")
        print(f"Test Case '{name}' {'skipped' if skipped else 'failed' if failed else 'passed'} (0.001 seconds).")
        failures += int(failed)
    print(f"Test Suite '{bundle}' {'failed' if failures else 'passed'} at fixture.")
    print(f"Executed {len(entries)} tests, with {failures} failures (0 unexpected) in 0.001 seconds")
    return failures


def main():
    root = Path(__file__).resolve().parent
    options = json.loads((root / "fake-runner.json").read_text())
    action = "list" if "list" in sys.argv[1:] else "worker" if "--worker" in sys.argv else "run"
    with (root / "fake-calls.jsonl").open("a") as stream:
        stream.write(json.dumps({"action": action, "pid": os.getpid(), "arguments": sys.argv[1:]}) + "\n")
    cases = options["cases"]
    if action == "list":
        print("\n".join(options.get("inventory", cases)))
        return
    if action == "worker":
        selector = sys.argv[sys.argv.index("--worker") + 1]
        selected = cases.copy() if options.get("ignore_filter") else [selector]
        selected = [case for case in selected if case != options.get("omit")]
        if options.get("empty"):
            selected = []
        if options.get("wrong_case"):
            selected = ["Unknown.Spurious/testOther"]
        if options.get("duplicate_case") in selected:
            selected.append(options["duplicate_case"])
        if options.get("unknown_case"):
            selected.append("Unknown.Spurious/testExtra")
        layout = options.get("layout", "aggregate")
        failures = 0
        if layout != "selected":
            print("Test Suite 'Selected tests' started at fixture.")
        if layout == "split":
            for module in dict.fromkeys(case.split(".", 1)[0] for case in [*cases, *selected]):
                failures += emit(
                    module + ".xctest", [case for case in selected if case.startswith(module + ".")], options
                )
        else:
            failures += emit(
                "Selected tests" if layout == "selected" else options.get("package", "Fixture") + "PackageTests.xctest",
                selected,
                options,
            )
        if layout != "selected":
            print(f"Test Suite 'Selected tests' {'failed' if failures else 'passed'} at fixture.")
            print(f"Executed {len(selected)} tests, with {failures} failures (0 unexpected) in 0.001 seconds")
        raise SystemExit(options.get("exit_code", 1 if failures else 0))

    assert "--parallel" in sys.argv and "--verbose" in sys.argv and "--skip-build" in sys.argv
    assert sys.argv[sys.argv.index("--num-workers") + 1] == "1"
    results = []
    for index, selector in enumerate(cases):
        result = subprocess.run([sys.executable, __file__, "--worker", selector], capture_output=True, text=True)
        print(f"[{index + 1}/{len(cases)}] Testing {selector}")
        results.append((selector, result))
    for _, result in results:
        print(result.stdout, end="")
        print(result.stderr, end="")
    report = ET.Element("testsuites")
    failures = sum(result.returncode != 0 for _, result in results)
    suite = ET.SubElement(
        report,
        "testsuite",
        name="TestResults",
        tests=str(len(results)),
        errors="0",
        failures=str(0 if options.get("force_xml_green") else failures),
        time="0.001",
    )
    for selector, result in results:
        owner, method = selector.split("/", 1)
        case = ET.SubElement(suite, "testcase", classname=owner, name=method, time="0.001")
        if result.returncode and not options.get("force_xml_green"):
            ET.SubElement(case, "failure", message="failed")
    primary = Path(sys.argv[sys.argv.index("--xunit-output") + 1])
    ET.ElementTree(report).write(primary, encoding="utf-8", xml_declaration=True)
    sidecar = ET.Element("testsuites")
    ET.SubElement(sidecar, "testsuite", name="TestResults", tests="0", errors="0", failures="0", skipped="0", time="0")
    ET.ElementTree(sidecar).write(
        primary.with_name(primary.stem + "-swift-testing.xml"), encoding="utf-8", xml_declaration=True
    )
    raise SystemExit(0 if options.get("force_exit_zero") else (1 if failures else options.get("exit_code", 0)))


if __name__ == "__main__":
    main()
