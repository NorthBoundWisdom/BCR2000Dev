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
