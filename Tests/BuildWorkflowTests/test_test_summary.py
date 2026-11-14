import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from configs import macos_workflow


class TestSummaryTests(unittest.TestCase):
    def summary(self, output, expected=None, returncode=0):
        rendered = io.StringIO()
        with contextlib.redirect_stdout(rendered):
            passed = macos_workflow.summarize_tests(output, expected or ["First.xctest", "Last.xctest"], returncode)
        return passed, rendered.getvalue()

    def bundle(self, name, status="passed", tests=4, failures=0):
        return f"Test Suite '{name}.xctest' {status} at now.\n Executed {tests} tests, with {failures} failures\n"

    def test_all_bundles_and_totals_are_reported(self):
        passed, output = self.summary(self.bundle("First") + self.bundle("Last", tests=7))
        self.assertTrue(passed)
        self.assertIn("PASS First.xctest: 4 tests", output)
        self.assertIn("PASS Last.xctest: 7 tests", output)
        self.assertIn("Total: 11 tests, 0 failures; PASS", output)

    def test_earlier_failure_is_not_hidden_by_last_success_or_zero_exit(self):
        passed, output = self.summary(self.bundle("First", "failed", failures=1) + self.bundle("Last"))
        self.assertFalse(passed)
        self.assertIn("FAIL First.xctest", output)
        self.assertIn("PASS Last.xctest", output)

    def test_failed_case_is_fatal_even_if_all_suite_summaries_claim_success(self):
        passed, output = self.summary(
            "Test Case '-[First broken]' failed (0.1 seconds).\n" + self.bundle("First") + self.bundle("Last")
        )
        self.assertFalse(passed)
        self.assertIn("FAIL Test Case '-[First broken]' failed", output)

    def test_missing_truncated_empty_and_nonzero_runs_fail_closed(self):
        for log, code in [
            (self.bundle("Last"), 0),
            ("", 0),
            (self.bundle("First") + "Test Suite 'Last.xctest' passed at now.\n", 0),
            (self.bundle("First") + self.bundle("Last"), 1),
        ]:
            with self.subTest(log=log, code=code):
                self.assertFalse(self.summary(log, returncode=code)[0])

    def fixture(self, name):
        return (Path(__file__).parent / "Fixtures" / name).read_text()

    def fake_swift(self, root, cases, **options):
        executable = root / "swift"
        executable.write_text(
            "#!" + sys.executable + "\n" + Path(__file__).with_name("fake_test_runner.py").read_text()
        )
        executable.chmod(0o755)
        (root / "fake-runner.json").write_text(json.dumps({"cases": cases, **options}))

    def run_fake_modules(self, root, modules, cases, *, required_modules=frozenset(), **options):
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
            patch.dict("os.environ", {"PATH": str(root) + ":/usr/bin:/bin"}),
            contextlib.redirect_stdout(output),
        ):
            macos_workflow.main(["test"])
        return output.getvalue()

    def aggregate_summary(self, output, returncode=0):
        expected = [
            "BCRPluginHostTests",
            "BCRAgentCoreTests",
            "BCRAgentConsoleTests",
            "BCRProviderDomainTests",
            "BCRProviderAdapterTests",
        ]
        rendered = io.StringIO()
        with contextlib.redirect_stdout(rendered):
            passed = macos_workflow.summarize_tests(
                output,
                [name + ".xctest" for name in expected],
                returncode,
                aggregate_name="BCRAgentConsolePackageTests.xctest",
            )
        return passed, rendered.getvalue()

    def test_real_aggregate_complete_passing_cases_are_accepted(self):
        passed, output = self.aggregate_summary(self.fixture("swift6_aggregate_success.txt"))
        self.assertTrue(passed)
        self.assertIn("Total: 529 tests, 0 failures; PASS", output)
        self.assertIn("BCRAgentConsoleTests: 157 started, 157 complete", output)

    def test_real_aggregate_failures_survive_zero_exit(self):
        passed, output = self.aggregate_summary(self.fixture("swift6_aggregate_failure.txt"))
        self.assertFalse(passed)
        self.assertIn("531 tests, 3 failures", output)
        self.assertIn("FAIL Test Case", output)

    def test_real_split_bundles_are_accepted(self):
        expected = [
            "BCRPluginHostTests",
            "BCRAgentCoreTests",
            "BCRAgentConsoleTests",
            "BCRProviderDomainTests",
            "BCRProviderAdapterTests",
        ]
        passed, output = self.summary(
            self.fixture("swift62_split_success.txt"), [name + ".xctest" for name in expected]
        )
        self.assertTrue(passed)
        self.assertIn("Total: 531 tests, 0 failures; PASS", output)

    def test_aggregate_missing_start_terminal_module_or_duplicate_is_rejected(self):
        valid = self.fixture("swift6_aggregate_success.txt")
        lines = valid.splitlines()
        started = next(line for line in lines if "Test Case" in line and "started" in line)
        terminal = next(line for line in lines if "Test Case" in line and "passed" in line)
        mutations = [
            valid.replace(started + "\n", "", 1),
            valid.replace(terminal + "\n", "", 1),
            "\n".join(line for line in lines if "BCRPluginHostTests." not in line),
            started + "\n" + valid,
            valid.replace(terminal, terminal + "\n" + terminal, 1),
            valid.replace(
                "Test Suite 'BCRAgentConsolePackageTests.xctest' started", "Test Suite 'Other.xctest' started"
            ),
            valid.replace("BCRProviderDomainTests.", "UnknownModule."),
            valid.split("Test Suite 'BCRAgentConsolePackageTests.xctest' passed", 1)[0],
            "",
        ]
        for output in mutations:
            with self.subTest(sample=output[:100]):
                self.assertFalse(self.aggregate_summary(output)[0])

    def test_aggregate_empty_count_mismatch_unexpected_and_nonzero_fail_closed(self):
        valid = self.fixture("swift6_aggregate_success.txt")
        for output in [
            valid.replace("Executed 529 tests", "Executed 530 tests"),
            valid.replace("0 failures (0 unexpected)", "0 failures (1 unexpected)"),
            valid.replace("0 failures (0 unexpected)", "1 failures (0 unexpected)"),
            valid.replace("Executed 529 tests", "Executed 0 tests"),
            "\n".join(line for line in valid.splitlines() if "Test Case" not in line),
        ]:
            self.assertFalse(self.aggregate_summary(output)[0])
        self.assertFalse(self.aggregate_summary(valid, returncode=1)[0])

    def test_aggregate_cli_reads_the_actual_package_name_and_target_modules(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            modules = [
                "BCRPluginHostTests",
                "BCRAgentCoreTests",
                "BCRAgentConsoleTests",
                "BCRProviderDomainTests",
                "BCRProviderAdapterTests",
            ]
            (root / "Package.swift").write_text(
                'Package(name: "BCRAgentConsole", targets: ['
                + ",".join('.testTarget(name: "' + name + '")' for name in modules)
                + "])"
            )
            import re

            cases = [
                match[1] + "/" + match[2]
                for match in re.finditer(
                    r"Test Case '-\[([^ ]+) ([^\]]+)\]' started", self.fixture("swift6_aggregate_success.txt")
                )
            ]
            self.fake_swift(root, cases, package="BCRAgentConsole", layout="aggregate")
            with (
                patch.object(macos_workflow, "REPO_ROOT", root),
                patch.object(macos_workflow, "ensure_dependency"),
                patch.dict("os.environ", {"PATH": str(root) + ":/usr/bin:/bin"}),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(macos_workflow.main(["test"]), 0)

    def test_cli_returns_nonzero_and_names_failed_bundle_with_fake_swift(self):
        # Exercise the real streaming runner and CLI, without modifying a production Swift test.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Package.swift").write_text('.testTarget(name: "First"), .testTarget(name: "Last")')
            self.fake_swift(
                root,
                [module + ".Sample/test" + str(index) for module in ["First", "Last"] for index in range(4)],
                layout="split",
                fail_module="First",
            )
            output = io.StringIO()
            with (
                patch.object(macos_workflow, "REPO_ROOT", root),
                patch.object(macos_workflow, "ensure_dependency"),
                patch.object(macos_workflow, "REQUIRED_TEST_MODULES", frozenset()),
                patch.dict("os.environ", {"PATH": str(root) + ":/usr/bin:/bin"}),
                contextlib.redirect_stdout(output),
            ):
                with self.assertRaisesRegex(RuntimeError, "bundle verification failed"):
                    macos_workflow.main(["test"])
            self.assertIn("FAIL First.xctest", output.getvalue())

    def test_runner_invokes_swift_test_once_and_accepts_both_layouts(self):
        cases = ["First.Sample/testOne", "First.Sample/testTwo", "Last.Sample/testThree"]
        for layout in ["aggregate", "split"]:
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                output = self.run_fake_modules(root, ["First", "Last"], cases, layout=layout)
                calls = [json.loads(line) for line in (root / "fake-calls.jsonl").read_text().splitlines()]
                self.assertEqual(len(calls), 1)
                self.assertNotIn("--num-workers", calls[0])
                self.assertIn("Total: 3 tests, 0 failures; PASS", output)
                self.assertTrue(list((root / "build/test-runs").glob("run-*/swift-test.log")))

    def test_failure_nonzero_exit_and_missing_module_fail_the_run(self):
        cases = ["First.Sample/testOne", "Last.Sample/testTwo"]
        for options in [{"fail_module": "First"}, {"exit_code": 7}]:
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

    def test_a_hung_test_is_killed_and_named(self):
        cases = ["First.Sample/testOne", "First.Sample/testHangs"]
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(macos_workflow, "TEST_TIMEOUT_S", 1),
        ):
            with self.assertRaisesRegex(RuntimeError, r"exceeded 1s while running -\[First.Sample testHangs\]"):
                self.run_fake_modules(Path(directory), ["First"], cases, hang_case="First.Sample/testHangs")


if __name__ == "__main__":
    unittest.main()
