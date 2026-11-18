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

    def test_serial_transport_mode_preserves_order_and_all_failure_logs(self):
        order = []

        def runner(command, stdout, stderr):
            order.append(command[0])
            stdout.write(command[0])
            return subprocess.CompletedProcess(command, int(command[0] == "fails"))

        with tempfile.TemporaryDirectory() as root:
            rows = execute([("first", ["fails"]), ("second", ["passes"])], Path(root), runner=runner, workers=1)
            self.assertEqual(order, ["fails", "passes"])
            self.assertEqual([row["returncode"] for row in rows], [1, 0])
            self.assertEqual((Path(root) / "first.log").read_text(), "fails")
            self.assertEqual((Path(root) / "second.log").read_text(), "passes")

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
        self.assertEqual(workflow.count("runs-on: macos-26\n"), 1)
        self.assertEqual(workflow.count("runs-on: macos-26-intel\n"), 1)
        self.assertLess(
            native.index("ci_parallel_checks.py tests"), native.index("Confirm native and isolated MCP products exited")
        )
        gui_checks = (
            "macos_workflow.py build --distribution ad-hoc",
            "macos_workflow.py smoke",
            "tools/mcp_integration.py",
            "git diff --check",
            "Confirm GUI smoke and isolated MCP products exited",
        )
        gui_positions = [delivery.index(check) for check in gui_checks]
        self.assertEqual(gui_positions, sorted(gui_positions))
        self.assertLess(delivery.index("verify_status_panel_demo.py"), gui_positions[0])
        self.assertLess(gui_positions[-1], delivery.index("Preserve delivery, GUI and timing evidence"))
        self.assertIn("if: ${{ !cancelled() }}", delivery[gui_positions[-1] :])
        for extension in ("log", "json", "jsonl", "txt"):
            path = f"build/mcp-integration/*/*.{extension}\n"
            self.assertNotIn(path, native)
            self.assertIn(path, delivery)
        self.assertIn("assert_ci_processes_exited.py", delivery)
        self.assertLess(delivery.index("package_provider.py"), delivery.index("assert_ci_processes_exited.py"))
        self.assertLess(
            delivery.index("assert_ci_processes_exited.py"), delivery.index("ci_parallel_checks.py transports")
        )
        self.assertLess(delivery.index("ci_parallel_checks.py transports"), delivery.index("verify_display_budget.py"))
        self.assertLess(delivery.index("verify_display_budget.py"), delivery.index("verify_status_panel_demo.py"))
        condition = delivery.split("id: package-provider\n", 1)[1].split("run:", 1)[0]
        self.assertIn("steps.compile.outcome == 'success'", condition)
        self.assertIn("steps.boundaries.outcome == 'success'", condition)
        self.assertNotIn("steps.tests", condition)
        self.assertNotIn("success()", condition)

    def test_merged_macos_phase_keeps_every_original_check_and_acceptance_command_once(self):
        # Same native/delivery command inventory, now split across independent VMs.
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        macos = workflow.split("  checks:\n")[1]
        commands = [
            "python3 configs/validate_repo_commands.py .",
            "python3 configs/display_budget_report.py --evidence docs/status-panel-budget-evidence.json --output docs/STATUS_PANEL_BUDGET.md --check",
            "python3 configs/check_accessibility.py",
            "python3 -m compileall -q configs",
            "python3 configs/ci_parallel_checks.py tests --native-precompiled",
            "python3 configs/macos_workflow.py build --distribution ad-hoc",
            "python3 configs/macos_workflow.py smoke",
            "python3 tools/mcp_integration.py",
            "python3 configs/package_provider.py --output build/ci-surface-provider --configuration debug --skip-build",
            "python3 build/ci-surface-provider/diagnostics/display_targets.py --directory build/ci-surface-provider --check",
            "python3 configs/ci_parallel_checks.py transports",
            "python3 configs/verify_display_budget.py --binary build/ci-surface-provider/BCRProviderService --output build/ci-display-budget",
            "python3 build/ci-surface-provider/diagnostics/verify_status_panel_demo.py --artifact build/ci-surface-provider --output build/ci-status-panel-demo",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(macos.count("run: " + command + "\n"), 1)
        for job in macos.split("  delivery:\n"):
            self.assertEqual(job.count("run: git diff --check\n"), 1)
        self.assertIn("name: test-logs-${{ github.run_id }}", macos)
        self.assertIn("name: delivery-checks-${{ github.run_id }}", macos)
        self.assertEqual(macos.count("Report whole-run wall time and enforce 300s budget"), 2)
        self.assertLess(macos.index("verify_status_panel_demo.py"), macos.rindex("Report whole-run wall time"))
