import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from configs import macos_workflow


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
    def fake_swift(self, root, cases, **options):
        executable = root / "swift"
        executable.write_text(
            "#!" + sys.executable + "\n" + Path(__file__).with_name("fake_test_runner.py").read_text()
        )
        executable.chmod(0o755)
        (root / "fake-runner.json").write_text(json.dumps({"cases": cases, **options}))

    def run_fake_modules(self, root, modules, cases, *, required_modules=frozenset(), workers="3", **options):
        (root / "Package.swift").write_text(
            'Package(name: "Fixture", targets: ['
            + ",".join('.testTarget(name: "' + name + '")' for name in modules)
            + "])"
        )
        self.fake_swift(root, cases, **options)
        output = io.StringIO()
        with (
            patch.object(macos_workflow, "REPO_ROOT", root),
            patch.object(macos_workflow, "ensure_dependency"),
            patch.object(macos_workflow, "REQUIRED_TEST_MODULES", required_modules),
            patch.dict("os.environ", {"PATH": str(root) + ":/usr/bin:/bin", "BCR_TEST_WORKERS": workers}),
            contextlib.redirect_stdout(output),
        ):
            macos_workflow.main(["test"])
        return output.getvalue()

    def test_runner_invokes_one_parallel_swift_test_with_an_xunit_report(self):
        cases = ["First.Sample/testOne", "First.Sample/testTwo", "Last.Sample/testThree"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = self.run_fake_modules(root, ["First", "Last"], cases)
            calls = [json.loads(line) for line in (root / "fake-calls.jsonl").read_text().splitlines()]
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][calls[0].index("--num-workers") + 1], "3")
            self.assertIn("--parallel", calls[0])
            self.assertIn("Total: 3 tests, 0 failures; PASS", output)
            self.assertTrue(list((root / "build/test-runs").glob("run-*/swift-test.log")))

    def test_failure_nonzero_exit_missing_report_and_missing_module_fail_the_run(self):
        cases = ["First.Sample/testOne", "Last.Sample/testTwo"]
        for options in [{"fail_module": "First"}, {"exit_code": 7}, {"omit_report": True}]:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(RuntimeError, "bundle verification failed"):
                    self.run_fake_modules(Path(directory), ["First", "Last"], cases, **options)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "bundle verification failed"):
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

    def test_a_hung_test_is_killed_and_named_among_the_last_started(self):
        cases = ["First.Sample/testOne", "First.Sample/testHangs"]
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(macos_workflow, "TEST_TIMEOUT_S", 1),
        ):
            with self.assertRaisesRegex(RuntimeError, r"exceeded 1s; last started: .*First.Sample/testHangs"):
                self.run_fake_modules(
                    Path(directory), ["First"], cases, hang_case="First.Sample/testHangs", workers="1"
                )

    def test_invalid_worker_override_is_rejected(self):
        with patch.dict("os.environ", {"BCR_TEST_WORKERS": "0"}), self.assertRaises(ValueError):
            macos_workflow.test_workers()


if __name__ == "__main__":
    unittest.main()
