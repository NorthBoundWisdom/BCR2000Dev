import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

from configs.ci_parallel_checks import execute


class IndependentCIChecksTests(unittest.TestCase):
    def test_checks_overlap_and_all_outcomes_are_retained(self):
        barrier = threading.Barrier(2)

        def runner(command, stdout, stderr):
            barrier.wait(timeout=5)
            stdout.write(command[0])
            return subprocess.CompletedProcess(command, int(command[0] == "fails"))

        with tempfile.TemporaryDirectory() as root:
            rows = execute([("first", ["passes"]), ("second", ["fails"])], Path(root), runner=runner)
            self.assertEqual([row["returncode"] for row in rows], [0, 1])
            self.assertTrue((Path(root) / "timing.json").exists())
            self.assertEqual((Path(root) / "first.log").read_text(), "passes")
            self.assertEqual((Path(root) / "second.log").read_text(), "fails")

    def test_duplicate_names_cannot_overwrite_logs(self):
        with tempfile.TemporaryDirectory() as root, self.assertRaises(ValueError):
            execute([("same", []), ("same", [])], Path(root))

    def test_failure_retains_other_command_completion_and_reports_full_error(self):
        import contextlib
        import io

        completed = []

        def runner(command, stdout, stderr):
            completed.append(command[0])
            if command[0] == "missing":
                raise FileNotFoundError("complete launch failure detail")
            stdout.write("other complete output")
            return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as root, contextlib.redirect_stdout(io.StringIO()) as output:
            rows = execute([("missing", ["missing"]), ("other", ["other"])], Path(root), runner=runner)
            self.assertEqual(sorted(completed), ["missing", "other"])
            self.assertEqual([r["returncode"] for r in rows], [127, 0])
            self.assertIn("complete launch failure detail", output.getvalue())
            self.assertEqual((Path(root) / "other.log").read_text(), "other complete output")

    def test_timing_sensitive_checks_have_isolated_steps_and_disjoint_outputs(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "configs/ci_parallel_checks.py").read_text()
        self.assertNotIn("verify_display_budget.py", source)
        self.assertNotIn("verify_status_panel_demo.py", source)
        workflow = (root / ".github/workflows/ci.yml").read_text()
        native, delivery = workflow.split("  delivery:\n")
        self.assertNotIn("ci_parallel_checks.py transports", native)
        self.assertIn("Isolated display budget latency", delivery)
        self.assertIn("Isolated real-time synthetic status", delivery)
        self.assertNotIn("needs:", workflow)
