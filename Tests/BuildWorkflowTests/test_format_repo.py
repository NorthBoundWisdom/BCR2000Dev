from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from configs import format_repo


class RepositoryFormattingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.git("init", "-q")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True).stdout

    def stage(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.git("add", "--", relative)
        return path

    def test_hook_fixes_worktree_then_stops_without_changing_index(self):
        path = self.stage("file with spaces.txt", b"hello  \r\n")
        self.assertEqual(format_repo.format_repository(self.root, staged=True), 1)
        self.assertEqual(path.read_bytes(), b"hello\n")
        self.assertEqual(self.git("show", ":file with spaces.txt"), b"hello  \r\n")
        self.git("add", "--", path.name)
        self.assertEqual(format_repo.format_repository(self.root, staged=True), 0)

    def test_partial_staging_prevents_all_writes(self):
        other = self.stage("a.txt", b"also dirty  \n")
        path = self.stage("b.txt", b"staged  \n")
        path.write_bytes(b"staged  \nunstaged\n")
        with self.assertRaisesRegex(RuntimeError, "Partially staged"):
            format_repo.format_repository(self.root, staged=True)
        self.assertEqual(path.read_bytes(), b"staged  \nunstaged\n")
        self.assertEqual(other.read_bytes(), b"also dirty  \n")
        self.assertEqual(self.git("show", ":b.txt"), b"staged  \n")

    def test_formatted_index_allows_unformatted_unstaged_content(self):
        path = self.stage("note.txt", b"staged\n")
        path.write_bytes(b"unstaged  \r\n")
        self.assertEqual(format_repo.format_repository(self.root, staged=True), 0)
        self.assertEqual(path.read_bytes(), b"unstaged  \r\n")

    def test_check_is_read_only_and_all_is_idempotent(self):
        path = self.stage("note.txt", b"hello  \r\n\n")
        untracked = self.root / "untracked.txt"
        untracked.write_bytes(b"untouched  \r\n")
        self.assertEqual(format_repo.format_repository(self.root, check=True), 1)
        self.assertEqual(path.read_bytes(), b"hello  \r\n\n")
        self.assertEqual(format_repo.format_repository(self.root), 0)
        self.assertEqual(format_repo.format_repository(self.root, check=True), 0)
        self.assertEqual(untracked.read_bytes(), b"untouched  \r\n")

    def test_skips_vendor_binary_symlinks_and_exact_byte_attributes(self):
        originals = {
            "configs/_vendor/source.py": b"vendor  \r\n",
            "binary.bin": b"\0binary  \r\n",
            "legacy.txt": b"\xff  \r\n",
            "fixture.txt": b"exact  \r\n",
        }
        for relative, data in originals.items():
            self.stage(relative, data)
        self.stage(".gitattributes", b"fixture.txt -text\n")
        outside = self.root.parent / (self.root.name + "-target")
        outside.write_bytes(b"external  \r\n")
        self.addCleanup(outside.unlink)
        (self.root / "link.txt").symlink_to(outside)
        self.git("add", "link.txt")
        self.assertEqual(format_repo.format_repository(self.root, staged=True), 0)
        for relative, data in originals.items():
            self.assertEqual((self.root / relative).read_bytes(), data)
        self.assertEqual(outside.read_bytes(), b"external  \r\n")
        self.assertTrue((self.root / "link.txt").is_symlink())

    def test_markdown_preserves_hard_line_breaks(self):
        self.assertEqual(format_repo.normalize(b"line  \r\nnext \n", markdown=True), b"line  \nnext\n")

    def test_missing_formatter_fails_before_any_write(self):
        path = self.stage("a.txt", b"dirty  \n")
        swift = self.stage("z.swift", b"let x=1\n")
        with patch.object(format_repo.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "swiftformat is required"):
                format_repo.format_repository(self.root, staged=True)
        self.assertEqual(path.read_bytes(), b"dirty  \n")
        self.assertEqual(swift.read_bytes(), b"let x=1\n")

    def test_formatter_failure_fails_before_any_write(self):
        path = self.stage("test.py", b"x=1\n")
        result = subprocess.CompletedProcess([], 1, b"", b"invalid source")
        with patch.object(format_repo.shutil, "which", return_value="ruff"):
            with patch.object(format_repo.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(RuntimeError, "invalid source"):
                    format_repo.format_content(self.root, path.name, path.read_bytes())
        self.assertEqual(path.read_bytes(), b"x=1\n")

    @unittest.skipUnless(shutil.which("swiftformat") and shutil.which("ruff"), "formatters not installed")
    def test_real_formatters_and_executable_hook(self):
        project = Path(__file__).resolve().parents[2]
        for relative in ("configs/format_repo.py", "configs/.swiftformat", "configs/githooks/pre-commit", "ruff.toml"):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(project / relative, target)
        swift = self.stage("sample.swift", b"let x=1\n")
        python = self.stage("sample.py", b'x=1\r\ntext="""first  \r\nlast  """\r\n')
        self.git("config", "core.hooksPath", "configs/githooks")
        self.git("config", "user.name", "Formatting Test")
        self.git("config", "user.email", "format-test@example.invalid")
        environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1")
        result = subprocess.run(
            ["git", "commit", "-m", "test formatting"], cwd=self.root, env=environment, capture_output=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Re-stage", result.stdout + result.stderr)
        self.assertEqual(swift.read_bytes(), b"let x = 1\n")
        self.assertEqual(python.read_bytes(), b'x = 1\ntext = """first  \nlast  """\n')
        self.git("add", "sample.swift", "sample.py")
        self.git("commit", "-m", "test formatting")


if __name__ == "__main__":
    unittest.main()
