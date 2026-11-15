import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET

from configs import macos_workflow, xctest_runner


class NativeInventoryTests(unittest.TestCase):
    def test_discovery_rejects_duplicates_missing_modules_and_unsupported_identifiers(self):
        self.assertEqual(
            xctest_runner.inventory("First.A/testOne\nLast.B/testTwo", ["First", "Last"]),
            ["First.A/testOne", "Last.B/testTwo"],
        )
        for text in ["", "First.A/testOne\nFirst.A/testOne", "First.A/testOne", "First.someSwiftTestingFunction()"]:
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                xctest_runner.inventory(text, ["First", "Last"])

    def test_partition_keeps_classes_together_covers_every_case_and_bounds_processes(self):
        cases = [
            f"{module}.Class{group}/test{index}"
            for module in ["First", "Last"]
            for group in range(7)
            for index in range(group + 1)
        ]
        jobs = xctest_runner.batches(cases, 3)
        self.assertEqual(len(jobs), 6)
        self.assertCountEqual([case for batch in jobs for case in batch.cases], cases)
        owners = [owner for batch in jobs for owner in batch.classes]
        self.assertEqual(len(owners), len(set(owners)))
        self.assertTrue(all(case.startswith(batch.module + ".") for batch in jobs for case in batch.cases))

    def test_accounting_requires_both_start_and_completion_exactly_once(self):
        expected = ("First.A/testOne",)
        start = "Test Case '-[First.A testOne]' started.\n"
        end = "Test Case '-[First.A testOne]' passed (0.003 seconds).\n"
        for output in [
            start,
            end,
            start + end + end,
            start + start + end,
            start + end + "Test Case '-[First.A unexpected]' passed (0.001 seconds).\n",
        ]:
            with self.subTest(output=output):
                self.assertTrue(xctest_runner.case_elements(output, expected)[1])
        elements, errors = xctest_runner.case_elements(start + end, expected)
        self.assertFalse(errors)
        self.assertEqual(elements[0].get("time"), "0.003")

    def test_default_backend_uses_native_batches_and_preserves_module_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Package.swift").write_text('.testTarget(name: "First"), .testTarget(name: "Last")')
            report = root / "result.xml"
            report.write_text(
                '<testsuites><testsuite><testcase classname="First.A" name="testOne"/>'
                '<testcase classname="Last.B" name="testTwo"/></testsuite></testsuites>'
            )
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.object(macos_workflow, "REPO_ROOT", root),
                patch.object(macos_workflow, "REQUIRED_TEST_MODULES", frozenset()),
                patch.object(macos_workflow, "test_workers", return_value=2),
                patch.object(xctest_runner, "run", return_value=(report, 0)) as run,
                patch.object(macos_workflow, "_run_case_tests") as legacy,
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                macos_workflow._run_tests(["swift", "test"])
            run.assert_called_once()
            self.assertEqual(run.call_args.args[1], ["First", "Last"])
            self.assertEqual(run.call_args.args[-2], 2)
            legacy.assert_not_called()
            self.assertIn("Total: 2 tests, 0 failures; PASS", output.getvalue())

    def test_legacy_backend_remains_explicit_and_invalid_modes_fail(self):
        with (
            patch.dict(os.environ, {"BCR_TEST_EXECUTION": "case"}),
            patch.object(macos_workflow, "_run_case_tests") as run,
        ):
            macos_workflow._run_tests(["swift", "test"])
            run.assert_called_once_with(["swift", "test"])
        with patch.dict(os.environ, {"BCR_TEST_EXECUTION": "unknown"}), self.assertRaises(ValueError):
            macos_workflow._run_tests(["swift", "test"])


class NativeExecutionTests(unittest.TestCase):
    def execute(self, directory, *, timeout=10, layout="split", **options):
        root = Path(directory)
        cases = ["First.A/testOne", "First.B/testTwo", "Last.C/testThree"]
        (root / "fixture.json").write_text(json.dumps({"cases": cases, **options}))
        executable = root / "fake-native"
        executable.write_text(
            "#!" + sys.executable + "\n" + Path(__file__).with_name("fake_native_xctest.py").read_text()
        )
        executable.chmod(0o755)
        if layout == "split":
            for module in ["First", "Last"]:
                (root / (module + ".xctest")).mkdir()
        elif layout == "aggregate":
            (root / "Package.swift").write_text('Package(name: "Fixture", targets: [])')
            (root / "FixturePackageTests.xctest").mkdir()
        run = root / "run"
        run.mkdir()
        with (
            patch.object(xctest_runner, "_checked", side_effect=["\n".join(cases), str(root), str(executable)]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            report, code = xctest_runner.run(["swift", "test"], ["First", "Last"], root, run, 2, timeout)
        return root, ET.parse(report).getroot(), code

    def test_real_processes_produce_complete_native_xunit_and_auditable_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root, report, code = self.execute(directory)
            self.assertEqual(code, 0)
            self.assertEqual(report.get("timing_source"), "xctest-body")
            self.assertEqual(len(list(report.iter("testcase"))), 3)
            self.assertFalse(list(report.iter("failure")))
            plan = json.loads((root / "run/plan.json").read_text())
            self.assertEqual(len(plan["cases"]), 3)
            self.assertEqual(plan["workers"], 2)
            self.assertTrue((root / "run/swift-test.log").is_file())
            timing = json.loads((root / "run/timing.json").read_text())
            self.assertAlmostEqual(timing["case_seconds"], 0.009)
            self.assertGreater(timing["batch_process_seconds"], timing["case_seconds"])

    def test_aggregate_package_bundle_of_older_toolchains_runs_every_case(self):
        with tempfile.TemporaryDirectory() as directory:
            root, report, code = self.execute(directory, layout="aggregate")
            self.assertEqual(code, 0)
            self.assertEqual(len(list(report.iter("testcase"))), 3)
            bundles = {json.loads(line) for line in (root / "bundles.jsonl").read_text().splitlines()}
            self.assertEqual(bundles, {str(root / "FixturePackageTests.xctest")})

    def test_partial_or_missing_bundle_layout_is_a_verification_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory)
            (binary / "First.xctest").mkdir()
            (binary / "FixturePackageTests.xctest").mkdir()
            with self.assertRaisesRegex(RuntimeError, "missing Last.xctest"):
                xctest_runner.test_bundles(binary, ["First", "Last"], "Fixture")
            with self.assertRaisesRegex(RuntimeError, "missing First.xctest, Last.xctest"):
                xctest_runner.test_bundles(binary / "none", ["First", "Last"], None)

    def test_native_assertion_failure_is_preserved_even_when_process_exits_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, code = self.execute(directory, status="failed")
            self.assertEqual(code, 0)  # Native assertions are checked independently by the xunit summary.
            self.assertEqual(len(list(report.iter("failure"))), 3)
            self.assertIn("original assertion failed", ET.tostring(report, encoding="unicode"))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(
                    macos_workflow.summarize_xunit([Path(directory) / "run/xunit.xml"], ["First", "Last"], code)
                )

    def test_missing_duplicate_unexpected_and_nonzero_process_exit_fail_closed(self):
        for options in [
            {"omit_start": "First.A/testOne"},
            {"omit_finish": "First.A/testOne"},
            {"duplicate": True},
            {"extra": ["First.A/unexpected"]},
            {"exit_code": 7},
        ]:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                _, report, code = self.execute(directory, **options)
                self.assertNotEqual(code, 0)
                self.assertTrue(list(report.iter("error")))

    def test_native_skip_is_reported_without_dropping_the_case(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, code = self.execute(directory, status="skipped")
            self.assertEqual(code, 0)
            self.assertEqual(len(list(report.iter("testcase"))), 3)
            self.assertEqual(len(list(report.iter("skipped"))), 3)

    def test_timeout_kills_owned_fixture_descendants_and_reports_incomplete_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            root, report, code = self.execute(directory, timeout=0.5, hang=True)
            self.assertNotEqual(code, 0)
            self.assertIn("exceeded suite timeout", ET.tostring(report, encoding="unicode"))
            pids = (root / "children.jsonl").read_text().splitlines()
            self.assertGreaterEqual(len(pids), 1)
            deadline = time.monotonic() + 2
            for pid in pids:
                while True:
                    state = subprocess.run(
                        ["ps", "-o", "stat=", "-p", pid], capture_output=True, text=True
                    ).stdout.strip()
                    if not state or state.startswith("Z"):
                        break
                    if time.monotonic() >= deadline:
                        self.fail("Timed-out fixture descendant is still running")
                    time.sleep(0.01)
