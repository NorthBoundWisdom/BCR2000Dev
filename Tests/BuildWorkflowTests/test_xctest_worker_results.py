from __future__ import annotations

import contextlib
import io
from pathlib import Path
import re
import tempfile
import unittest

from configs.macos_workflow import summarize_tests
from configs.xctest_worker_results import WorkerResultError, validate_workers

FIXTURES = Path(__file__).parent / "Fixtures"
CASES = [
    "BCRAgentConsoleTests.SSEStreamTests/testBackpressureActuallyClosesTheClientConnection",
    "BCRAgentConsoleTests.SSEStreamTests/testBurstCoalescesIntoOneLatestValueEvent",
]


class XCTestWorkerResultsTests(unittest.TestCase):
    def fixture(self, name):
        return (FIXTURES / name).read_text()

    def validate(self, output=None, primary=None, sidecar=None, *, missing=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [root / "xctest.xml", root / "xctest-swift-testing.xml"]
            for path, contents, default in zip(
                paths,
                (primary, sidecar),
                ("swift_worker_two_success.xml", "swift_worker_zero_testing.xml"),
                strict=True,
            ):
                if missing != path.name:
                    path.write_text(self.fixture(default) if contents is None else contents)
            with contextlib.redirect_stdout(io.StringIO()):
                return validate_workers(
                    self.fixture("swift_worker_verbose_two_success.txt") if output is None else output,
                    *paths,
                    {"BCRAgentConsoleTests": set(CASES)},
                    "BCRAgentConsolePackageTests.xctest",
                    summarize_tests,
                )

    def test_real_verbose_success_binds_two_actual_children_to_progress_and_xml(self):
        report = self.validate()
        self.assertEqual(report["tests"], 2)
        self.assertEqual([row["selector"] for row in report["workers"]], CASES)
        self.assertTrue(all(row["passed"] and row["started"] == row["completed"] == 1 for row in report["workers"]))
        self.assertEqual(report["swift_testing_tests"], 0)

    def test_missing_duplicate_unknown_progress_or_wrong_total_is_fatal(self):
        raw = self.fixture("swift_worker_verbose_two_success.txt")
        first = raw.splitlines()[0]
        for output in (
            raw.replace(first, "", 1),
            first + "\n" + raw,
            raw.replace("[2/2]", "[1/2]"),
            raw.replace("[1/2]", "[1/3]"),
            raw.replace(CASES[0], "Unknown.Case/testExtra", 1),
        ):
            with self.subTest(output=output[:100]), self.assertRaises(WorkerResultError):
                self.validate(output=output)

    def test_green_xml_cannot_hide_skipped_empty_wrong_duplicate_or_truncated_actual_child(self):
        raw = self.fixture("swift_worker_verbose_two_success.txt")
        boundary = raw.index("Test Suite 'Selected tests' started")
        prefix, children = raw[:boundary], raw[boundary:]
        first_method = CASES[0].split("/")[1]
        no_cases = "\n".join(line for line in children.splitlines() if "Test Case '" not in line).replace(
            "Executed 1 test", "Executed 0 tests"
        )
        for changed in (
            children.replace(" passed (", " skipped (", 1),
            no_cases,
            children.replace(first_method, "testWrongButExitZero"),
            children + children,
            children[: children.rfind("Test Suite 'Selected tests' passed")],
            children.replace("with 0 failures", "with 1 failures", 1),
            children.replace("0 unexpected", "1 unexpected", 1),
        ):
            with self.subTest(changed=changed[-100:]), self.assertRaises(WorkerResultError):
                self.validate(output=prefix + changed)

    def test_late_xctest_records_or_errors_outside_complete_children_are_fatal(self):
        raw = self.fixture("swift_worker_verbose_two_success.txt")
        for extra in (
            "Executed 1 test, with 1 failure",
            "Test Suite 'Late' failed at fixture.",
            "Test Case '-[Unknown.Case testExtra]' started.",
            "error: worker unexpectedly terminated",
        ):
            with self.subTest(extra=extra), self.assertRaises(WorkerResultError):
                self.validate(output=raw + "\n" + extra + "\n")

    def test_primary_xml_missing_malformed_duplicate_unknown_or_conflicting_results_fail(self):
        xml = self.fixture("swift_worker_two_success.xml")
        for changed in (
            "{broken",
            xml.replace('tests="2"', 'tests="1"'),
            xml.replace('failures="0"', 'failures="1"'),
            xml.replace('errors="0"', 'errors="1"'),
            xml.replace('errors="0"', 'skipped="1" errors="0"'),
            xml.replace('time="', 'status="skipped" time="', 1),
            xml.replace('name="testBackpressureActuallyClosesTheClientConnection"', 'name="testWrong"'),
            xml.replace('classname="BCRAgentConsoleTests.SSEStreamTests"', 'classname="Unknown.Suite"'),
            xml.replace("</testcase>", '<failure message="failed"/></testcase>', 1),
            xml.replace("</testcase>", "failure text</testcase>", 1),
            xml.replace("</testcase>", "</testcase>unexpected tail", 1),
            re.sub(r'time="[^"]+"', 'time="nan"', xml, count=1),
            xml.replace("<testsuites>", '<testsuites tests="3">'),
        ):
            with self.subTest(changed=changed[:100]), self.assertRaises(WorkerResultError):
                self.validate(primary=changed)
        for missing in ("xctest.xml", "xctest-swift-testing.xml"):
            with self.subTest(missing=missing), self.assertRaises(WorkerResultError):
                self.validate(missing=missing)

    def test_hidden_status_attributes_text_or_nonzero_swift_testing_are_not_ignored(self):
        xml = self.fixture("swift_worker_two_success.xml")
        for attribute in ("status", "result", "outcome", "disabled"):
            changed = xml.replace("<testcase ", f'<testcase {attribute}="skipped" ', 1)
            with self.subTest(attribute=attribute), self.assertRaises(WorkerResultError):
                self.validate(primary=changed)
        zero = self.fixture("swift_worker_zero_testing.xml")
        for changed in (
            zero.replace('tests="0"', 'tests="1"', 1),
            zero.replace('skipped="0"', 'skipped="1"', 1),
            zero.replace('failures="0"', 'failures="1"', 1),
            zero.replace('errors="0"', 'errors="1"', 1),
            zero.replace("/>", '><testcase classname="Extra" name="test" time="0"/></testsuite>', 1),
        ):
            with self.subTest(changed=changed[:100]), self.assertRaises(WorkerResultError):
                self.validate(sidecar=changed)
