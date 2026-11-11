from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

from configs import surface_plugins_dependency as dependency


class SurfacePluginsDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.root = self.directory / "host"
        (self.root / "configs").mkdir(parents=True)
        self.source = self.directory / "source"
        self.source.mkdir()
        self.git(self.source, "init", "--quiet")
        self.git(self.source, "config", "user.email", "fixture@example.invalid")
        self.git(self.source, "config", "user.name", "Dependency fixture")
        (self.source / "Package.swift").write_text("// committed package\n")
        (self.source / ".gitignore").write_text("ignored.txt\n")
        self.first = self.commit("first")
        self.spec = {"schemaVersion": 1, "remote": "https://example.invalid/SurfacePlugins.git", "revision": self.first}
        self.write_lock()
        self.environment = dict(os.environ)
        self.environment.pop(dependency.LEGACY_SOURCE_ENV, None)
        self.environment[dependency.SOURCE_ENV] = str(self.source)

    def git(self, directory, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(directory), *arguments], text=True, stderr=subprocess.DEVNULL
        ).strip()

    def commit(self, message):
        self.git(self.source, "add", ".")
        self.git(self.source, "commit", "--quiet", "-m", message)
        return self.git(self.source, "rev-parse", "HEAD")

    def write_lock(self):
        (self.root / dependency.LOCK_FILE).write_text(json.dumps(self.spec))

    def ensure(self, **kwargs):
        return dependency.ensure_dependency(self.root, environ=self.environment, **kwargs)

    def test_fetches_only_the_locked_committed_content_and_preserves_dirty_source(self):
        (self.source / "Package.swift").write_text("// dirty change must stay outside build\n")
        (self.source / "new.txt").write_text("uncommitted")
        destination = self.ensure()
        self.assertEqual(destination, self.root / dependency.CACHE_PATH)
        self.assertEqual((destination / "Package.swift").read_text(), "// committed package\n")
        self.assertFalse((destination / "new.txt").exists())
        self.assertEqual((self.source / "Package.swift").read_text(), "// dirty change must stay outside build\n")
        self.assertEqual(self.git(destination, "rev-parse", "HEAD"), self.first)
        self.assertEqual(self.git(destination, "remote", "get-url", "origin"), self.spec["remote"])

    def test_valid_cache_is_offline_and_verify_is_read_only(self):
        destination = self.ensure()
        before = {
            str(path.relative_to(destination)): path.stat().st_mtime_ns
            for path in destination.rglob("*")
            if path.is_file()
        }
        environment = dict(self.environment)
        environment.pop(dependency.SOURCE_ENV)
        with patch.object(dependency, "_materialize", side_effect=AssertionError("must not fetch again")):
            self.assertEqual(dependency.ensure_dependency(self.root, environ=environment), destination)
            self.assertEqual(
                dependency.ensure_dependency(self.root, environ=environment, verify_only=True), destination
            )
        after = {
            str(path.relative_to(destination)): path.stat().st_mtime_ns
            for path in destination.rglob("*")
            if path.is_file()
        }
        self.assertEqual(after, before)

    def test_dirty_cache_including_ignored_files_is_never_replaced_even_by_update(self):
        destination = self.ensure()
        for name in ("Package.swift", "new.txt", "ignored.txt"):
            with self.subTest(name=name):
                path = destination / name
                old = path.read_text() if path.exists() else None
                path.write_text("preserve my dirty cache")
                for arguments in ({}, {"update": True}, {"verify_only": True}):
                    with self.assertRaises(dependency.DependencyError):
                        self.ensure(**arguments)
                self.assertEqual(path.read_text(), "preserve my dirty cache")
                if old is None:
                    path.unlink()
                else:
                    path.write_text(old)

    def test_lock_update_requires_explicit_update_and_exact_committed_sha(self):
        destination = self.ensure()
        (self.source / "Package.swift").write_text("// second committed package\n")
        second = self.commit("second")
        self.spec["revision"] = second
        self.write_lock()
        with self.assertRaises(dependency.DependencyError):
            self.ensure()
        self.assertEqual(self.git(destination, "rev-parse", "HEAD"), self.first)
        self.assertEqual(self.ensure(update=True), destination)
        self.assertEqual(self.git(destination, "rev-parse", "HEAD"), second)
        self.assertEqual((destination / "Package.swift").read_text(), "// second committed package\n")
        self.assertFalse(list(destination.parent.glob(".SurfacePlugins-stage-*")))
        self.assertFalse(list(destination.parent.glob(".SurfacePlugins-previous-*")))

    def test_missing_commit_fails_without_changing_a_valid_previous_materialization(self):
        destination = self.ensure()
        self.spec["revision"] = "a" * 40
        self.write_lock()
        with self.assertRaises(dependency.DependencyError):
            self.ensure(update=True)
        self.assertEqual(self.git(destination, "rev-parse", "HEAD"), self.first)
        self.assertFalse(list(destination.parent.glob(".SurfacePlugins-stage-*")))

    def test_head_that_disagrees_with_marker_is_not_reset(self):
        destination = self.ensure()
        self.git(destination, "config", "user.email", "fixture@example.invalid")
        self.git(destination, "config", "user.name", "Dependency fixture")
        (destination / "Package.swift").write_text("// user commit\n")
        self.git(destination, "add", ".")
        self.git(destination, "commit", "--quiet", "-m", "user commit")
        actual = self.git(destination, "rev-parse", "HEAD")
        with self.assertRaises(dependency.DependencyError):
            self.ensure(update=True)
        self.assertEqual(self.git(destination, "rev-parse", "HEAD"), actual)

    def test_unmanaged_or_symlink_destination_is_preserved(self):
        parent = self.root / "build/dependencies"
        parent.mkdir(parents=True)
        destination = parent / "SurfacePlugins"
        destination.mkdir()
        (destination / "user.txt").write_text("preserve")
        with self.assertRaises(dependency.DependencyError):
            self.ensure(update=True)
        self.assertEqual((destination / "user.txt").read_text(), "preserve")
        (destination / "user.txt").unlink()
        destination.rmdir()
        destination.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(dependency.DependencyError):
            self.ensure(update=True)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.first)

    def test_symlinked_parent_git_metadata_or_ownership_marker_is_rejected(self):
        (self.root / "build").symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(dependency.DependencyError):
            self.ensure()
        (self.root / "build").unlink()
        destination = self.ensure()
        marker = destination / ".git" / dependency.MARKER
        marker.unlink()
        outside = self.directory / "marker.json"
        outside.write_text(json.dumps(self.spec))
        marker.symlink_to(outside)
        with self.assertRaises(dependency.DependencyError):
            self.ensure(update=True)
        self.assertTrue(marker.is_symlink())
        marker.unlink()
        marker.write_text(json.dumps(self.spec))
        git = destination / ".git"
        preserved = destination / ".git-preserved"
        git.rename(preserved)
        git.symlink_to(preserved, target_is_directory=True)
        with self.assertRaises(dependency.DependencyError):
            self.ensure(update=True)
        self.assertTrue(git.is_symlink())

    def test_invalid_lock_and_conflicting_source_overrides_fail_visibly(self):
        for revision in ("main", "abc123", "A" * 40):
            self.spec["revision"] = revision
            self.write_lock()
            with self.assertRaises(dependency.DependencyError):
                self.ensure()
        self.spec["revision"] = self.first
        self.write_lock()
        self.environment[dependency.LEGACY_SOURCE_ENV] = str(self.directory / "another-source")
        with self.assertRaises(dependency.DependencyError):
            self.ensure()
        self.environment[dependency.LEGACY_SOURCE_ENV] = str(self.source)
        self.environment.pop(dependency.SOURCE_ENV)
        self.assertEqual(self.ensure(), self.root / dependency.CACHE_PATH)

    def test_parallel_initializers_share_one_atomic_materialization(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            outputs = list(pool.map(lambda _: self.ensure(), range(2)))
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(self.git(outputs[0], "rev-parse", "HEAD"), self.first)
        self.assertFalse(list(outputs[0].parent.glob(".SurfacePlugins-stage-*")))

    def test_user_changes_during_acquisition_are_preserved_in_place(self):
        destination = self.ensure()
        (self.source / "Package.swift").write_text("// second committed package\n")
        self.spec["revision"] = self.commit("second")
        self.write_lock()
        materialize = dependency._materialize

        def acquire(*args):
            stage = materialize(*args)
            (destination / "user.txt").write_text("changed while fetching")
            return stage

        with patch.object(dependency, "_materialize", side_effect=acquire):
            with self.assertRaises(dependency.DependencyError):
                self.ensure(update=True)
        self.assertEqual((destination / "user.txt").read_text(), "changed while fetching")
        self.assertEqual(self.git(destination, "rev-parse", "HEAD"), self.first)
        self.assertFalse(list(destination.parent.glob(".SurfacePlugins-stage-*")))
