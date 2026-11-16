import contextlib
import io
import json
import signal
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from configs import macos_workflow, xctest_runner


def report(directory, cases):
    """cases: (classname, name, outcome) with outcome passed|failed|error|skipped."""
    body = {"passed": "", "failed": "<failure message='x'/>", "error": "<error message='x'/>", "skipped": "<skipped/>"}
    path = Path(directory) / "xunit.xml"
    path.write_text(
        "<testsuites><testsuite name='TestResults'>"
        + "".join(
            f"<testcase classname='{owner}' name='{name}'>{body[outcome]}</testcase>" for owner, name, outcome in cases
        )
        + "</testsuite></testsuites>"
    )
    return path


class XunitSummaryTests(unittest.TestCase):
    def summary(self, cases, expected=("First", "Last"), returncode=0, extra=()):
        with tempfile.TemporaryDirectory() as directory:
            paths = [report(directory, cases), *extra]
            rendered = io.StringIO()
            with contextlib.redirect_stdout(rendered):
                passed = macos_workflow.summarize_xunit(paths, list(expected), returncode)
        return passed, rendered.getvalue()

    def test_every_module_with_passing_cases_is_accepted_and_totals_reported(self):
        passed, output = self.summary(
            [("First.A", "test1", "passed"), ("First.A", "test2", "skipped"), ("Last.B", "test3", "passed")]
        )
        self.assertTrue(passed)
        self.assertIn("PASS First: 2 tests, 0 failures, 1 skipped", output)
        self.assertIn("PASS Last: 1 tests, 0 failures, 0 skipped", output)
        self.assertIn("Total: 3 tests, 0 failures; PASS", output)

    def test_failures_and_errors_are_fatal_and_named_even_with_zero_exit(self):
        for outcome in ("failed", "error"):
            with self.subTest(outcome=outcome):
                passed, output = self.summary([("First.A", "broken", outcome), ("Last.B", "fine", "passed")])
                self.assertFalse(passed)
                self.assertIn("FAIL First.A.broken", output)
                self.assertIn("FAIL First:", output)

    def test_missing_module_empty_nonzero_and_unreadable_reports_fail_closed(self):
        self.assertFalse(self.summary([("First.A", "only", "passed")])[0])
        self.assertFalse(self.summary([])[0])
        self.assertFalse(self.summary([("First.A", "t", "passed"), ("Last.B", "t", "passed")], returncode=1)[0])
        with tempfile.TemporaryDirectory() as directory:
            broken = Path(directory) / "broken.xml"
            broken.write_text("<testsuites><testcase")
            cases = [("First.A", "t", "passed"), ("Last.B", "t", "passed")]
            self.assertFalse(self.summary(cases, extra=[broken])[0])
        rendered = io.StringIO()
        with contextlib.redirect_stdout(rendered):
            self.assertFalse(macos_workflow.summarize_xunit([], ["First"], 0))

    def test_cases_from_a_second_report_count_toward_their_module(self):
        with tempfile.TemporaryDirectory() as directory:
            swift_testing = Path(directory) / "xunit-swift-testing.xml"
            swift_testing.write_text(
                "<testsuites><testsuite><testcase classname='Last.Suite' name='t()'/></testsuite></testsuites>"
            )
            self.assertTrue(self.summary([("First.A", "t", "passed")], extra=[swift_testing])[0])


class ParallelRunnerTests(unittest.TestCase):
    def fake_swift(self, root, cases, modules, **options):
        fixture = Path(__file__).with_name("fake_test_runner.py").read_text()
        for name in ("swift", "xcrun"):
            executable = root / name
            executable.write_text("#!" + sys.executable + " -S\n" + fixture)
            executable.chmod(0o755)
        native = root / "native-xctest"
        native.write_text(
            "#!" + sys.executable + " -S\n" + Path(__file__).with_name("fake_native_xctest.py").read_text()
        )
        native.chmod(0o755)
        for name in modules:
            (root / (name + ".xctest")).mkdir()
        translated = dict(options)
        if translated.pop("fail_module", None):
            translated["status"] = "failed"
        if translated.pop("omit_report", False):
            translated["omit_finish"] = cases[0]
        (root / "fixture.json").write_text(json.dumps({"cases": cases, **translated}))

    def run_fake_modules(
        self, root, modules, cases, *, required_modules=frozenset(), workers="3", precompiled=False, **options
    ):
        (root / "Package.swift").write_text(
            'Package(name: "Fixture", targets: ['
            + ",".join('.testTarget(name: "' + name + '")' for name in modules)
            + "])"
        )
        self.fake_swift(root, cases, modules, **options)
        output = io.StringIO()
        with (
            patch.object(macos_workflow, "REPO_ROOT", root),
            patch.object(macos_workflow, "ensure_dependency"),
            patch.object(macos_workflow, "REQUIRED_TEST_MODULES", required_modules),
            patch.dict(
                "os.environ",
                {"PATH": str(root) + ":/usr/bin:/bin", "BCR_TEST_WORKERS": workers, "BCR_TEST_EXECUTION": "batch"},
            ),
            contextlib.redirect_stdout(output),
        ):
            macos_workflow.main(["test"] + (["--precompiled-tests"] if precompiled else []))
        return output.getvalue()

    def test_runner_uses_one_discovery_and_bounded_native_batches_with_xunit(self):
        cases = ["First.Sample/testOne", "First.Sample/testTwo", "Last.Sample/testThree"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = self.run_fake_modules(root, ["First", "Last"], cases)
            calls = [json.loads(line) for line in (root / "fake-calls.jsonl").read_text().splitlines()]
            self.assertEqual(len([row for row in calls if row[0:2] == ["swift", "test"] and row[-1] == "list"]), 1)
            plan = json.loads(next((root / "build/test-runs").glob("run-*/plan.json")).read_text())
            self.assertEqual(plan["workers"], 3)
            self.assertCountEqual(plan["cases"], cases)
            self.assertLessEqual(len(plan["batches"]), 6)
            native_calls = [json.loads(row) for row in (root / "calls.jsonl").read_text().splitlines()]
            self.assertEqual(len(native_calls), len(plan["batches"]))
            self.assertIn("Total: 3 tests, 0 failures; PASS", output)
            self.assertTrue(list((root / "build/test-runs").glob("run-*/swift-test.log")))

    def test_precompiled_discovery_still_reconciles_every_native_case_once(self):
        cases = ["First.Sample/testOne", "Last.Sample/testTwo"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = self.run_fake_modules(root, ["First", "Last"], cases, precompiled=True)
            calls = [json.loads(line) for line in (root / "fake-calls.jsonl").read_text().splitlines()]
            discovered = [row for row in calls if row[:2] == ["swift", "test"] and "list" in row]
            self.assertEqual(len(discovered), 1)
            self.assertEqual(discovered[0][-2:], ["list", "--skip-build"])
            plan = json.loads(next((root / "build/test-runs").glob("run-*/plan.json")).read_text())
            self.assertCountEqual(plan["cases"], cases)
            self.assertIn("Total: 2 tests, 0 failures; PASS", output)

    def test_precompiled_discovery_still_fails_on_missing_native_completion(self):
        cases = ["First.Sample/testOne", "Last.Sample/testTwo"]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "bundle verification failed"):
                self.run_fake_modules(Path(directory), ["First", "Last"], cases, precompiled=True, omit_report=True)

    def test_failure_nonzero_exit_missing_native_results_and_missing_module_fail_the_run(self):
        cases = ["First.Sample/testOne", "Last.Sample/testTwo"]
        for options in [{"fail_module": "First"}, {"exit_code": 7}, {"omit_report": True}]:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(RuntimeError, "bundle verification failed"):
                    self.run_fake_modules(Path(directory), ["First", "Last"], cases, **options)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "Discovered modules differ"):
                self.run_fake_modules(Path(directory), ["First", "Last"], cases[:1])

    def test_required_module_missing_from_the_manifest_is_fatal(self):
        modules = sorted(macos_workflow.REQUIRED_TEST_MODULES)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "required test module is missing"):
                self.run_fake_modules(
                    Path(directory),
                    modules[1:],
                    [module + ".Sample/testOne" for module in modules[1:]],
                    required_modules=macos_workflow.REQUIRED_TEST_MODULES,
                )

    def test_a_hung_native_batch_is_killed_and_missing_case_is_named(self):
        cases = ["First.Sample/testOne", "First.Sample/testHangs"]
        processes = []
        native_popen = subprocess.Popen

        def record_process(*args, **kwargs):
            process = native_popen(*args, **kwargs)
            processes.append(process)
            return process

        def prepared(command, root, log, deadline):
            # This case measures native-hang termination. Other runner tests exercise the CLI
            # preparation; three Python startup processes must not consume its one-second budget.
            if command[-1] == "list":
                output = "\n".join(cases)
            elif command[-1] == "--show-bin-path":
                output = str(root)
            else:
                self.assertEqual(command, ["xcrun", "--find", "xctest"])
                output = str(root / "native-xctest")
            log.write_text(output)
            return output

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(macos_workflow, "TEST_TIMEOUT_S", 1),
            patch.object(xctest_runner, "_checked", side_effect=prepared),
            patch.object(xctest_runner.subprocess, "Popen", side_effect=record_process),
        ):
            with self.assertRaisesRegex(RuntimeError, "bundle verification failed"):
                self.run_fake_modules(
                    Path(directory), ["First"], cases, hang_case="First.Sample/testHangs", workers="1"
                )
            self.assertEqual(len(processes), 1)
            self.assertEqual(processes[0].returncode, -signal.SIGKILL)
            run = next((Path(directory) / "build/test-runs").glob("run-*"))
            self.assertIn("First.Sample/testHangs", (run / "xunit.xml").read_text())
            self.assertIn("exceeded suite timeout 1s", (run / "xunit.xml").read_text())
            self.assertIn("testHangs", (run / "swift-test.log").read_text())

    def test_invalid_worker_override_is_rejected(self):
        with patch.dict("os.environ", {"BCR_TEST_WORKERS": "0"}), self.assertRaises(ValueError):
            macos_workflow.test_workers()


if __name__ == "__main__":
    unittest.main()
