import contextlib
import io
from pathlib import Path
import subprocess
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
            executable = root / "swift"
            executable.write_text(
                "#!/bin/sh\ncat <<'RESULTS'\n" + self.fixture("swift6_aggregate_success.txt") + "RESULTS\nexit 0\n"
            )
            executable.chmod(0o755)
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
            executable = root / "swift"
            executable.write_text(
                "#!/bin/sh\ncat <<'RESULTS'\n"
                + self.bundle("First", "failed", failures=1)
                + self.bundle("Last")
                + "RESULTS\nexit 0\n"
            )
            executable.chmod(0o755)
            output = io.StringIO()
            with (
                patch.object(macos_workflow, "REPO_ROOT", root),
                patch.object(macos_workflow, "ensure_dependency"),
                patch.dict("os.environ", {"PATH": str(root) + ":/usr/bin:/bin"}),
                contextlib.redirect_stdout(output),
            ):
                with self.assertRaisesRegex(RuntimeError, "bundle verification failed"):
                    macos_workflow.main(["test"])
            self.assertIn("FAIL First.xctest", output.getvalue())


if __name__ == "__main__":
    unittest.main()
