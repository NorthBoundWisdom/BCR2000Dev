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
        self.assertEqual(text.count("timeout-minutes: 20"), 3)
        self.assertEqual(text.count("Report whole-run wall time and enforce 300s budget"), 3)
        linux, tail = text.split("  checks:\n")
        native, delivery = tail.split("  delivery:\n")
        self.assertLess(linux.index("Compile portable"), linux.index("Save compiled portable"))
        self.assertLess(linux.index("Save compiled portable"), linux.index("Run and reconcile"))
        self.assertLess(native.index("run: python3 configs/ci_native_compile.py"), native.index("Save compiled native"))
        self.assertLess(native.index("Save compiled native"), native.index("ci_parallel_checks.py tests"))
        self.assertIn("steps.compile.outputs.native_build_succeeded == 'true'", native)
        self.assertIn("steps.compile.outputs.audit_helpers_succeeded == 'true'", native)
        self.assertIn("if: always() && steps.compile.outcome == 'success'", linux)
        self.assertIn("if: always() && steps.compile.outcome == 'success'", delivery)
        self.assertLess(delivery.index("Compile provider"), delivery.index("Save compiled delivery"))
        self.assertLess(delivery.index("Save compiled delivery"), delivery.index("package_provider.py"))
        self.assertIn("steps.compile.outcome == 'success' && steps.boundaries.outcome == 'success'", delivery)
        self.assertIn("--configuration debug --skip-build", delivery)

    def test_compilation_does_not_execute_discovery_and_cold_measurement_only_skips_restore(self):
        root = Path(__file__).resolve().parents[2]
        text = (root / ".github/workflows/ci.yml").read_text()
        compiler = (root / "configs/ci_native_compile.py").read_text()
        self.assertEqual(text.count("--build-tests"), 1)
        self.assertIn('"--build-tests"', compiler)
        self.assertNotIn("id: compile\n        run: swift test", text)
        self.assertIn("list --skip-build", text)
        self.assertIn("tests --native-precompiled", text)
        self.assertEqual(text.count("inputs.cold_build != true"), 4)
        self.assertIn("Run and reconcile every portable XCTest once", text)
        native, delivery = text.split("  checks:\n")[1].split("  delivery:\n")
        self.assertNotIn("--build-tests", delivery)
        self.assertIn("--product BCRProviderService", delivery)
        self.assertIn("--product BCRProfileTool", delivery)
        self.assertLess(
            native.index("run: python3 configs/ci_native_compile.py"),
            native.index("run: python3 configs/check_domain_boundaries.py"),
        )
        self.assertLess(
            native.index("run: python3 configs/check_domain_boundaries.py"), native.index("ci_parallel_checks.py tests")
        )
        self.assertIn('"--scratch-path"', (root / "configs/check_domain_boundaries.py").read_text())

    def test_native_binary_cache_is_scoped_to_selected_runner_image(self):
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        native, delivery = text.split("  checks:\n")[1].split("  delivery:\n")
        self.assertEqual(text.count("runs-on: macos-26-intel\n"), 2)
        self.assertEqual(native.count("swiftpm-${{ runner.os }}-macos-26-intel-${{ env.SWIFT_ID }}"), 3)
        self.assertNotIn("swiftpm-${{ runner.os }}-${{ env.SWIFT_ID }}", text)
        self.assertIn("swiftpm-${{ runner.os }}-macos-26-intel-${{ env.SWIFT_ID }}-", delivery)
        self.assertIn("key: delivery-${{ runner.os }}-macos-26-intel-${{ env.SWIFT_ID }}", delivery)
        self.assertNotIn("key: swiftpm-", delivery)
        for recipe in (
            "tools/desktop_audit.swift",
            "tools/desktop_focus_host.swift",
            "tools/native_ui.py",
            "configs/ci_native_compile.py",
        ):
            self.assertEqual(native.count(recipe), 3 if recipe == "configs/ci_native_compile.py" else 2)
        self.assertEqual(native.count("build/tools/desktop_audit"), 2)
        self.assertEqual(native.count("build/tools/desktop_focus_host"), 2)
