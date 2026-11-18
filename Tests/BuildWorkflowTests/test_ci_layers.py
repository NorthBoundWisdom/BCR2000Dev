import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET

from configs import ci_prepare_inputs, xctest_runner


class CILayerIntegrityTests(unittest.TestCase):
    def test_fixed_selection_is_exact_and_missing_or_duplicate_case_fails_before_execution(self):
        cases = ("First.A/testOne", "First.A/testTwo", "Last.C/testThree")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for selected in ((), (cases[0], cases[0]), ("First.A/notDiscovered",)):
                with (
                    self.subTest(selected=selected),
                    patch.object(xctest_runner, "_checked", return_value="\n".join(cases)),
                    patch.object(xctest_runner.subprocess, "Popen") as launch,
                    self.assertRaises(RuntimeError),
                ):
                    xctest_runner.run(["swift", "test"], ["First", "Last"], root, root, 1, 5, selected_cases=selected)
                launch.assert_not_called()

    def test_exact_method_selection_records_full_discovery_and_rejects_unselected_output(self):
        cases = ("First.A/testOne", "First.A/testTwo", "Last.C/testThree")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for module in ("First", "Last"):
                (root / (module + ".xctest")).mkdir()
            executable = root / "native"
            executable.write_text(
                "#!" + sys.executable + " -S\nimport sys\n"
                "for selected in sys.argv[2].split(','):\n"
                " owner,method=selected.split('/')\n"
                " print(\"Test Case '-[%s %s]' started.\" % (owner,method))\n"
                " print(\"Test Case '-[%s %s]' passed (0.003 seconds).\" % (owner,method))\n"
            )
            executable.chmod(0o755)
            with (
                patch.object(xctest_runner, "_checked", side_effect=["\n".join(cases), str(root), str(executable)]),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                report, code = xctest_runner.run(
                    ["swift", "test"], ["First", "Last"], root, root, 1, 10, selected_cases=(cases[0], cases[2])
                )
            self.assertEqual(code, 0)
            plan = json.loads((root / "plan.json").read_text())
            self.assertEqual(plan["discovered_cases"], list(cases))
            self.assertEqual(plan["cases"], [cases[0], cases[2]])
            self.assertEqual(len(list(ET.parse(report).getroot().iter("testcase"))), 2)
            self.assertTrue(
                xctest_runner.case_elements(
                    "Test Case '-[First.A testTwo]' started.\nTest Case '-[First.A testTwo]' passed (0.003 seconds).\n",
                    (cases[0],),
                )[1]
            )

    def test_dirty_or_wrong_dependency_identity_is_fatal_before_timestamp_write(self):
        with (
            patch.object(ci_prepare_inputs, "ensure_dependency", side_effect=RuntimeError("dirty or wrong revision")),
            patch.object(ci_prepare_inputs.subprocess, "run") as launch,
            self.assertRaisesRegex(RuntimeError, "dirty"),
        ):
            ci_prepare_inputs.main()
        launch.assert_not_called()

    def test_tracked_git_timestamp_restore_is_stable_without_content_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            source = root / "source.swift"
            source.write_text("let value = 1\n")
            subprocess.run(["git", "-C", str(root), "add", "source.swift"], check=True)
            env = {
                **os.environ,
                "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z",
                "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z",
            }
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root),
                    "-c",
                    "user.name=CI fixture",
                    "-c",
                    "user.email=fixture@example.invalid",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                check=True,
                env=env,
            )
            for drift in (1710000000, 1720000000):
                os.utime(source, (drift, drift))
                with (
                    patch.object(ci_prepare_inputs, "ensure_dependency", return_value=root),
                    patch.object(ci_prepare_inputs, "ensure_kit_dependency", return_value=root),
                ):
                    ci_prepare_inputs.main()
                self.assertEqual(source.stat().st_mtime, 1577836800)
                self.assertEqual(source.read_text(), "let value = 1\n")
                self.assertEqual(subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"]), b"")
