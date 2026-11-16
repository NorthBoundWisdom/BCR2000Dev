"""Run discovered XCTest classes in bounded native-process batches, with exact case accounting."""

from __future__ import annotations

from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time
from xml.etree import ElementTree as ET


# XCTest's native identifiers, not a source-code approximation of the test inventory.
IDENTIFIER = re.compile(r"[^\s,/.]+\.[^\s,/]+/[^\s,]+\Z")
START = re.compile(r"Test Case '-\[([^ ]+) ([^]]+)\]' started\.")
FINISH = re.compile(r"Test Case '-\[([^ ]+) ([^]]+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)\.")


@dataclass(frozen=True)
class Batch:
    module: str
    classes: tuple[str, ...]
    cases: tuple[str, ...]


def inventory(output: str, modules: list[str]) -> list[str]:
    cases = output.splitlines()
    if not cases or any(not IDENTIFIER.fullmatch(case) for case in cases):
        raise RuntimeError("Invalid/unsupported discovery output; batch mode requires native XCTest identifiers")
    if len(cases) != len(set(cases)):
        raise RuntimeError("Duplicate discovered test identifier")
    discovered = {case.split(".", 1)[0] for case in cases}
    if discovered != set(modules):
        raise RuntimeError(f"Discovered modules differ from manifest: {sorted(discovered)} != {sorted(modules)}")
    return cases


def batches(cases: list[str], workers: int) -> list[Batch]:
    grouped = defaultdict(lambda: defaultdict(list))
    for case in cases:
        owner = case.split("/", 1)[0]
        grouped[owner.split(".", 1)[0]][owner].append(case)
    result = []
    for module, classes in sorted(grouped.items()):
        buckets = [[] for _ in range(min(workers, len(classes)))]
        loads = [0] * len(buckets)
        # Keep a class together; distribute larger inventories first without machine-specific timings.
        for owner in sorted(classes, key=lambda name: (-len(classes[name]), name)):
            index = min(range(len(buckets)), key=lambda i: (loads[i], i))
            buckets[index].append(owner)
            loads[index] += len(classes[owner])
        result.extend(
            Batch(module, tuple(bucket), tuple(case for owner in bucket for case in classes[owner]))
            for bucket in buckets
        )
    return sorted(result, key=lambda batch: (-len(batch.cases), batch.module, batch.classes))


def case_elements(output: str, expected: tuple[str, ...]) -> tuple[list[ET.Element], list[str]]:
    started, completed = Counter(), Counter()
    elements, errors = [], []
    current = None
    details = defaultdict(list)
    for line in output.splitlines():
        if match := START.fullmatch(line):
            current = f"{match[1]}/{match[2]}"
            started[current] += 1
        elif match := FINISH.fullmatch(line):
            owner, name, status, duration = match.groups()
            identifier = f"{owner}/{name}"
            completed[identifier] += 1
            case = ET.Element("testcase", classname=owner, name=name, time=duration)
            if status != "passed":
                child = ET.SubElement(case, "failure" if status == "failed" else "skipped", message=status)
                child.text = "\n".join(details[identifier])
            elements.append(case)
            current = None
        elif current and ("error:" in line or "Test skipped" in line):
            details[current].append(line)
    wanted = Counter(expected)
    for label, observed in [("started", started), ("completed", completed)]:
        if observed != wanted:
            errors.append(
                f"Inventory mismatch ({label}): missing={list((wanted - observed).elements())}; "
                f"extra/duplicate={list((observed - wanted).elements())}"
            )
    return elements, errors


def test_bundles(binary: Path, modules: list[str], package: str | None) -> dict[str, Path]:
    """Per-target bundles (newer SwiftPM) or the one aggregate package bundle (older toolchains).

    Class identifiers are module-qualified, so an aggregate bundle selects exactly the same classes.
    A partial per-target layout, or neither layout, is a verification failure.
    """
    split = {module: binary / (module + ".xctest") for module in modules}
    if all(path.is_dir() for path in split.values()):
        return split
    aggregate = binary / f"{package}PackageTests.xctest" if package else None
    if aggregate is not None and aggregate.is_dir() and not any(path.is_dir() for path in split.values()):
        return dict.fromkeys(modules, aggregate)
    missing = ", ".join(module + ".xctest" for module, path in split.items() if not path.is_dir())
    raise RuntimeError(f"Test bundle verification failed: missing {missing}")


def _checked(command: list[str], root: Path, log: Path, deadline: float) -> str:
    result = subprocess.run(
        command, cwd=root, capture_output=True, text=True, timeout=max(0.001, deadline - time.monotonic())
    )
    log.write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Test preparation failed ({result.returncode}); see {log}")
    return result.stdout.strip()


def run(
    command: list[str],
    modules: list[str],
    root: Path,
    directory: Path,
    workers: int,
    timeout: float,
    *,
    precompiled: bool = False,
) -> tuple[Path, int]:
    """Build/list once, run each selected class exactly once, then emit native per-case xunit."""
    started = time.monotonic()
    deadline = started + timeout
    discovery = command + ["list"] + (["--skip-build"] if precompiled else [])
    cases = inventory(_checked(discovery, root, directory / "discovery.log", deadline), modules)
    binary = Path(
        _checked([command[0], "build", *command[2:], "--show-bin-path"], root, directory / "binary-path.log", deadline)
    )
    executable = _checked(["xcrun", "--find", "xctest"], root, directory / "xctest-path.log", deadline)
    jobs = batches(cases, workers)
    manifest = root / "Package.swift"
    package = re.search(r'\bPackage\(\s*name:\s*"([^"]+)"', manifest.read_text()) if manifest.is_file() else None
    bundles = test_bundles(binary, modules, package[1] if package else None)
    plan = {
        "workers": workers,
        "cases": cases,
        "batches": [{"module": batch.module, "classes": batch.classes, "cases": batch.cases} for batch in jobs],
    }
    (directory / "plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    print(f"Discovered {len(cases)} tests; {len(jobs)} native batches, {workers} workers", flush=True)
    print_lock = threading.Lock()

    def execute(item):
        index, batch = item
        path = directory / f"batch-{index:03d}-{batch.module}.log"
        began = time.monotonic()
        errors = []
        code = 1
        if began >= deadline:
            path.write_text("Suite deadline reached before batch launch\n", encoding="utf-8")
            return [], [f"Batch {index} exceeded suite timeout {timeout}s before launch: {batch.classes}"], 0, path
        with print_lock:
            print(f"[{index + 1}/{len(jobs)}] Testing {batch.module}: {len(batch.cases)} cases", flush=True)
        with path.open("w", encoding="utf-8") as log:
            # Each owned process group includes its subprocess fixtures. A timeout kills that group.
            with subprocess.Popen(
                [executable, "-XCTest", ",".join(batch.classes), str(bundles[batch.module])],
                cwd=root,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            ) as process:
                try:
                    code = process.wait(timeout=max(0.001, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    errors.append(f"Batch {index} exceeded suite timeout {timeout}s: {batch.classes}")
                finally:
                    # Also reap owned fixtures after a crashed/finished native host; never leave
                    # subprocesses behind to affect a later test or hold its ports open.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
        output = path.read_text(encoding="utf-8", errors="replace")
        elements, integrity = case_elements(output, batch.cases)
        errors.extend(integrity)
        if code:
            errors.append(f"Batch {index} exited with {code}; see {path.name}")
        return elements, errors, time.monotonic() - began, path

    with ThreadPoolExecutor(max_workers=workers) as executor:
        results = list(executor.map(execute, enumerate(jobs)))
    report = ET.Element("testsuites", timing_source="xctest-body")
    suite = ET.SubElement(report, "testsuite", name="NativeXCTest")
    errors = []
    with (directory / "swift-test.log").open("w", encoding="utf-8") as log:
        for elements, failures, _, path in results:
            suite.extend(elements)
            errors.extend(failures)
            log.write(f"\nBatch log: {path.name}\n{path.read_text(encoding='utf-8', errors='replace')}")
    # Infrastructure failures must remain fatal even if every emitted native case says 'passed'.
    if errors:
        case = ET.SubElement(
            suite, "testcase", classname="BCRTestRunner.Integrity", name="inventory_and_processes", time="0"
        )
        ET.SubElement(case, "error", message="Native test execution was incomplete").text = "\n".join(errors)
        for error in errors:
            print(error, flush=True)
    suite.set("tests", str(len(suite)))
    suite.set(
        "failures", str(sum(case.find("failure") is not None or case.find("error") is not None for case in suite))
    )
    suite.set("skipped", str(sum(case.find("skipped") is not None for case in suite)))
    suite.set("time", str(sum(float(case.get("time", "0")) for case in suite)))
    xunit = directory / "xunit.xml"
    ET.indent(report)
    ET.ElementTree(report).write(xunit, encoding="utf-8", xml_declaration=True)
    (directory / "timing.json").write_text(
        json.dumps(
            {
                "timing_source": "xctest-body",
                "case_seconds": float(suite.get("time")),
                "batch_process_seconds": sum(result[2] for result in results),
                "wall_seconds": time.monotonic() - started,
                "batches": len(jobs),
                "cases": len(cases),
                "workers": workers,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return xunit, int(bool(errors))
