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
