import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from configs import ci_native_compile


class NativeCICompilationTests(unittest.TestCase):
    def test_native_and_original_helper_branches_overlap_and_both_are_joined(self):
        barrier = threading.Barrier(2)
        completed = []

        def runner(command, stdout, stderr):
            barrier.wait(timeout=5)
            stdout.write("compiled " + command[0])
            completed.append(command)
            return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rows = ci_native_compile.prepare(root, runner=runner)
            self.assertEqual([r["returncode"] for r in rows], [0, 0])
            self.assertEqual(rows[0]["command"], ["swift", "build", "--build-path", "build/swiftpm", "--build-tests"])
            self.assertEqual(rows[1]["command"][-1], "--helpers-only")
            self.assertEqual(len(completed), 2)
            self.assertEqual(len(json.loads((root / "build/ci-verification/compile/timing.json").read_text())), 2)
            for row in rows:
                self.assertTrue(Path(row["log"]).is_file())

    def test_one_failed_branch_does_not_hide_other_result_or_claim_compile_success(self):
        for failed in ("native", "audit-helpers"):
            rows = [{"name": name, "returncode": int(name == failed)} for name in ("native", "audit-helpers")]
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "outputs"
                with patch.object(ci_native_compile, "prepare", return_value=rows):
                    with (
                        patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}),
                        contextlib.redirect_stdout(io.StringIO()),
                    ):
                        self.assertEqual(ci_native_compile.main([]), 1)
                fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(fields["native_build_succeeded"], str(failed != "native").lower())
                self.assertEqual(fields["audit_helpers_succeeded"], str(failed != "audit-helpers").lower())

    def test_helper_precompile_calls_the_existing_recipe_without_launching_gui(self):
        with patch("tools.native_ui.native_binary") as binary, patch.object(ci_native_compile, "prepare") as prepare:
            self.assertEqual(ci_native_compile.main(["--helpers-only"]), 0)
        self.assertEqual([call.args for call in binary.call_args_list], [("desktop_audit",), ("desktop_focus_host",)])
        prepare.assert_not_called()
