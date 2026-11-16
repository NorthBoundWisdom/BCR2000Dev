import unittest
from datetime import datetime, timezone
from pathlib import Path

from configs.ci_job_budget import report


class CIJobBudgetTests(unittest.TestCase):
    def run_record(self):
        return {"id": 1, "created_at": "2026-11-16T00:00:00Z"}

    def job(self):
        return {
            "name": "checks",
            "started_at": "2026-11-16T00:00:00Z",
            "steps": [
                {
                    "name": "Compile",
                    "status": "completed",
                    "conclusion": "success",
                    "started_at": "2026-11-16T00:00:10Z",
                    "completed_at": "2026-11-16T00:02:00Z",
                },
                {
                    "name": "Tests",
                    "status": "completed",
                    "conclusion": "failure",
                    "started_at": "2026-11-16T00:02:00Z",
                    "completed_at": "2026-11-16T00:05:01Z",
                },
            ],
        }

    def test_cold_cache_whole_run_over_budget_fails(self):
        text, failed = report(self.run_record(), self.job(), "", datetime(2026, 11, 16, 0, 5, 1, tzinfo=timezone.utc))
        self.assertTrue(failed)
        self.assertIn("cold build cache", text)
        self.assertIn("301.0s", text)
        self.assertIn("| Tests | failure | 181.0 |", text)

    def test_restored_prefix_is_warm_and_over_budget_fails(self):
        text, failed = report(
            self.run_record(),
            self.job(),
            "swiftpm-mac-tool-previous-sha",
            datetime(2026, 11, 16, 0, 5, 1, tzinfo=timezone.utc),
        )
        self.assertTrue(failed)
        self.assertIn("301.0s", text)
        self.assertIn("Compile | success | 110.0", text)

    def test_exact_budget_boundary_passes(self):
        _, failed = report(self.run_record(), self.job(), "key", datetime(2026, 11, 16, 0, 5, tzinfo=timezone.utc))
        self.assertFalse(failed)

    def test_queue_and_late_job_cannot_bypass_whole_run_budget(self):
        job = self.job()
        job["started_at"] = "2026-11-16T00:04:50Z"
        text, failed = report(self.run_record(), job, "", datetime(2026, 11, 16, 0, 5, 1, tzinfo=timezone.utc))
        self.assertTrue(failed)
        self.assertIn("11.0s job wall time", text)
        self.assertIn("301.0s since run creation", text)
        self.assertIn("post-job cleanup", text)

    def test_cold_cache_exact_boundary_still_passes_without_exemption(self):
        text, failed = report(self.run_record(), self.job(), "", datetime(2026, 11, 16, 0, 5, tzinfo=timezone.utc))
        self.assertFalse(failed)
        self.assertIn("no cold-cache exemption", text)

    def test_both_jobs_save_after_compile_before_tests_independently_of_test_success(self):
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        self.assertEqual(text.count("timeout-minutes: 20"), 2)
        self.assertEqual(
            text.count("if: always() && steps.compile.outcome == 'success' && github.event_name == 'push'"), 2
        )
        self.assertEqual(text.count("Report whole-run wall time and enforce 300s budget"), 2)
        linux, native = text.split("  checks:\n")
        self.assertLess(linux.index("Save compiled portable"), linux.index("Run and reconcile"))
        self.assertLess(native.index("Save compiled native"), native.index("ci_parallel_checks.py tests"))
        self.assertLess(linux.index("Compile portable"), linux.index("Save compiled portable"))
        self.assertLess(native.index("Compile native"), native.index("Save compiled native"))
        self.assertEqual(linux.count("steps.compile.outcome == 'success'"), 1)
        self.assertEqual(
            native.count("if: always() && steps.compile.outcome == 'success' && github.event_name == 'push'"), 1
        )
        self.assertNotIn("--product BCRProviderService", native)
        self.assertNotIn("--product BCRProfileTool", native)
        self.assertIn("--configuration debug --skip-build", native)

    def test_compilation_does_not_execute_discovery_and_cold_measurement_only_skips_restore(self):
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        self.assertEqual(text.count("--build-tests"), 2)
        self.assertNotIn("id: compile\n        run: swift test", text)
        self.assertIn("list --skip-build", text)
        self.assertEqual(text.count("inputs.cold_build != true"), 2)
        self.assertIn("Run and reconcile every portable XCTest once", text)
