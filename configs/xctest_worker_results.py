"""Cross-check SwiftPM worker progress, actual XCTest output, and both xUnit reports."""

from __future__ import annotations

from collections import Counter
import math
from pathlib import Path
import re
import xml.etree.ElementTree as ET


class WorkerResultError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise WorkerResultError(message)


def number(element, name, *, optional=False):
    value = element.get(name, "0" if optional else "")
    require(re.fullmatch(r"[0-9]+", value) is not None, f"Invalid xUnit {name}")
    return int(value)


def duration(element):
    try:
        value = float(element.get("time", ""))
    except ValueError:
        raise WorkerResultError("Invalid xUnit duration") from None
    require(math.isfinite(value) and value >= 0, "Invalid xUnit duration")


def xml_report(path):
    require(path.is_file() and not path.is_symlink(), "Missing or unsafe xUnit report")
    raw = path.read_bytes()
    require(b"<!DOCTYPE" not in raw and b"<!ENTITY" not in raw, "Unsupported xUnit declarations")
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        raise WorkerResultError("Malformed xUnit report") from None
    require(root.tag == "testsuites" and len(root) > 0, "Invalid xUnit root")
    require(all(node.tag == "testsuite" for node in root), "Unknown xUnit root content")
    require(set(root.attrib) <= {"tests", "failures", "errors", "skipped", "time"}, "Unknown xUnit root attributes")
    for node in root.iter():
        require(not (node.text or "").strip() and not (node.tail or "").strip(), "Unexpected xUnit text")
    for suite in root:
        require(
            set(suite.attrib) <= {"name", "tests", "failures", "errors", "skipped", "time"},
            "Unknown xUnit suite attributes",
        )
        require(bool(suite.get("name")), "Missing xUnit suite name")
        duration(suite)
        require(all(node.tag == "testcase" for node in suite), "Unknown xUnit suite content")
        require(number(suite, "tests") == len(suite), "xUnit suite count differs from testcase count")
        require(
            number(suite, "failures") == 0
            and number(suite, "errors") == 0
            and number(suite, "skipped", optional=True) == 0,
            "xUnit suite failed, errored, or skipped",
        )
        for case in suite:
            require(
                set(case.attrib) <= {"classname", "name", "time", "failures", "errors", "skipped"},
                "Unknown xUnit testcase attributes",
            )
            require(not list(case), "xUnit testcase failed, errored, skipped, or has unsupported content")
            require(
                number(case, "failures", optional=True) == 0
                and number(case, "errors", optional=True) == 0
                and number(case, "skipped", optional=True) == 0,
                "xUnit testcase has nonzero status",
            )
            duration(case)
    for field in ("tests", "failures", "errors", "skipped"):
        if field in root.attrib:
            expected = sum(number(suite, field, optional=field == "skipped") for suite in root)
            require(number(root, field) == expected, "xUnit root count conflicts with suites")
    return root


def child_suites(block):
    stack, pending, valid = [], None, True
    for line in block.splitlines():
        start = re.match(r"Test Suite '([^']+)' started\b", line)
        terminal = re.match(r"Test Suite '([^']+)' (passed|failed)\b", line)
        counts = re.match(r"[ \t]*Executed ([0-9]+) tests?, with ([0-9]+) failures?(?: \(([0-9]+) unexpected\))?", line)
        if start:
            require(pending is None, "Child suite has no result count")
            stack.append([start[1], 0])
        elif terminal:
            require(pending is None and stack and stack[-1][0] == terminal[1], "Child suite nesting/terminal differs")
            _, total = stack.pop()
            pending = total
            valid = valid and terminal[2] == "passed"
        elif counts:
            require(pending is not None, "Unbound child result count")
            valid = valid and int(counts[1]) == pending and counts[2] == "0" and counts[3] in (None, "0")
            pending = None
        elif re.match(r"Test Case '[^']+' started\b", line):
            require(bool(stack) and pending is None, "Case started outside child suite")
            for entry in stack:
                entry[1] += 1
    require(not stack and pending is None, "Incomplete child suite result")
    return valid


def validate_workers(output, primary, sidecar, inventory, aggregate_name, summarize):
    expected = set().union(*inventory.values())
    require(bool(expected), "Empty worker inventory")
    raw_valid = not re.search(
        r"(^|\n)[^\n]*\berror:|Test Case '[^']+' (?:failed|skipped)\b|"
        r"Test Suite '[^']+' failed\b|\b[1-9][0-9]* (?:tests? )?skipped\b",
        output,
    )
    progress = []
    for line in output.splitlines():
        if re.match(r"^\[.*\]\s+Testing\b", line):
            match = re.fullmatch(r"\[([0-9]+)/([0-9]+)\] Testing ([^\s]+)", line)
            require(match is not None, "Malformed worker progress")
            progress.append((int(match[1]), int(match[2]), match[3]))
    require([row[0] for row in progress] == list(range(1, len(expected) + 1)), "Incomplete/duplicate worker progress")
    require(all(row[1] == len(expected) for row in progress), "Worker progress total differs from inventory")
    selectors = [row[2] for row in progress]
    require(Counter(selectors) == Counter(expected), "Worker progress selectors differ from inventory")

    starts = list(re.finditer(r"(?m)^Test Suite 'Selected tests' started\b", output))
    require(len(starts) == len(expected), "Missing or duplicate actual XCTest child output")
    blocks, spans, roots_valid = [], [], True
    for index, start in enumerate(starts):
        stop = starts[index + 1].start() if index + 1 < len(starts) else len(output)
        segment = output[start.start() : stop]
        terminals = list(
            re.finditer(
                r"Test Suite 'Selected tests' (passed|failed)\b[^\n]*\n[ \t]*"
                r"Executed ([0-9]+) tests?, with ([0-9]+) failures?(?: \(([0-9]+) unexpected\))?[^\n]*",
                segment,
            )
        )
        require(len(terminals) == 1, "Missing or duplicate child root terminal")
        terminal = terminals[0]
        roots_valid = roots_valid and (
            terminal[1] == "passed" and terminal[2] == "1" and terminal[3] == "0" and terminal[4] in (None, "0")
        )
        blocks.append(segment[: terminal.end()])
        spans.append((start.start(), start.start() + terminal.end()))
    for match in re.finditer(
        r"(?m)^[ \t]*(?:Test Case '[^']+' (?:started|passed|failed|skipped)\b|"
        r"Test Suite '[^']+' (?:started|passed|failed)\b|Executed [0-9]+ tests?,)",
        output,
    ):
        require(any(start <= match.start() < end for start, end in spans), "XCTest result outside a worker root")

    observed, valid, workers = set(), True, []
    all_bundles = {module + ".xctest" for module in inventory}
    for selector, block in zip(selectors, blocks, strict=True):
        roots_valid = child_suites(block) and roots_valid
        module = selector.split(".", 1)[0]
        statistics = {}
        passed = summarize(
            block,
            [module + ".xctest"],
            0,
            aggregate_name=aggregate_name,
            case_inventory={selector},
            empty_bundles=all_bundles - {module + ".xctest"},
            statistics=statistics,
        )
        identities = statistics["identifiers"]
        valid = valid and passed and not bool(observed & identities)
        observed.update(identities)
        workers.append(
            {
                "selector": selector,
                "passed": passed,
                "started": statistics["started"],
                "completed": statistics["completed"],
            }
        )
    require(
        valid and raw_valid and roots_valid and observed == expected,
        "Actual child coverage/status differs from the worker inventory",
    )
    report = xml_report(Path(primary))
    xml_cases = [case for suite in report for case in suite]
    identities = [f"{case.get('classname', '')}/{case.get('name', '')}" for case in xml_cases]
    require(Counter(identities) == Counter(expected), "xUnit testcase identities differ from inventory")
    require(identities == selectors, "xUnit order differs from completed worker progress")
    other = xml_report(Path(sidecar))
    require(
        not list(other.iter("testcase")) and all(number(suite, "tests") == 0 for suite in other),
        "Swift Testing cases need a separately supported isolation policy",
    )
    return {"tests": len(expected), "workers": workers, "swift_testing_tests": 0}
