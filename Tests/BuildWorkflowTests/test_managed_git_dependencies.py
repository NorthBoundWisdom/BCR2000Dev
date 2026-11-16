from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from configs import control_surface_kit_dependency as kit
from configs import surface_plugins_dependency as plugins


class ManagedGitDependenciesTests(unittest.TestCase):
    """The same destructive-failure cases apply independently to both dependency namespaces."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "host"
        (self.root / "configs").mkdir(parents=True)
        self.modules = (plugins, kit)
        self.environment = dict(os.environ)
        self.sources = {}
        self.specs = {}
        for module in self.modules:
            self.environment.pop(module.SOURCE_ENV, None)
            self.environment.pop(module.LEGACY_SOURCE_ENV, None)
            source = self.base / module.LAYOUT.name
            source.mkdir()
            self.git(source, "init", "--quiet", "--initial-branch=main")
            self.git(source, "config", "user.email", "fixture@example.invalid")
            self.git(source, "config", "user.name", "Managed dependency fixture")
            (source / "Package.swift").write_text(f"// {module.LAYOUT.name} committed package\n")
            (source / ".gitignore").write_text("ignored.txt\n")
            self.sources[module] = source
            revision = self.commit(module, "first")
            self.specs[module] = {
                "schemaVersion": 1,
                "remote": f"https://example.invalid/{module.LAYOUT.name}.git",
                "revision": revision,
            }
            self.write_lock(module)
            self.environment[module.SOURCE_ENV] = str(source)

    def git(self, directory, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(directory), *arguments], text=True, stderr=subprocess.DEVNULL
        ).strip()

    def commit(self, module, message):
        source = self.sources[module]
        self.git(source, "add", ".")
        self.git(source, "commit", "--quiet", "-m", message)
        return self.git(source, "rev-parse", "HEAD")

    def write_lock(self, module):
        (self.root / module.LOCK_FILE).write_text(json.dumps(self.specs[module]))

    def ensure(self, module, **kwargs):
        return module.ensure_dependency(self.root, environ=self.environment, **kwargs)

    def advance(self, module):
        (self.sources[module] / "Package.swift").write_text(f"// {module.LAYOUT.name} second package\n")
        self.specs[module]["revision"] = self.commit(module, "second")
        self.write_lock(module)

    def test_committed_content_only_and_distinct_remote_marker_and_source_namespaces(self):
        for module in self.modules:
            with self.subTest(dependency=module.LAYOUT.name):
                source = self.sources[module]
                (source / "Package.swift").write_text("// user dirty source\n")
                (source / "untracked.txt").write_text("preserve user source\n")
                destination = self.ensure(module)
                self.assertEqual(destination, self.root / module.CACHE_PATH)
                self.assertEqual(
                    (destination / "Package.swift").read_text(), f"// {module.LAYOUT.name} committed package\n"
                )
                self.assertFalse((destination / "untracked.txt").exists())
                self.assertEqual((source / "Package.swift").read_text(), "// user dirty source\n")
                self.assertEqual(self.git(destination, "remote", "get-url", "origin"), self.specs[module]["remote"])
                self.assertEqual(json.loads((destination / ".git" / module.MARKER).read_text()), self.specs[module])
                other = kit if module is plugins else plugins
                self.assertFalse((destination / ".git" / other.MARKER).exists())

    def test_exact_full_sha_and_https_lock_required_for_both(self):
        for module in self.modules:
            original = dict(self.specs[module])
            invalid = [
                {"revision": "main"},
                {"revision": "abc123"},
                {"revision": "A" * 40},
                {"revision": "a" * 39},
                {"remote": "file:///user/source"},
                {"remote": "https://example.invalid/repo\nother"},
                {"schemaVersion": True},
            ]
            for change in invalid:
                with self.subTest(dependency=module.LAYOUT.name, field=next(iter(change))):
                    self.specs[module] = {**original, **change}
                    self.write_lock(module)
                    with self.assertRaises(module.DependencyError):
                        self.ensure(module)
            self.specs[module] = original
            self.write_lock(module)
            self.assertEqual(self.git(self.ensure(module), "rev-parse", "HEAD"), original["revision"])

    def test_cached_verify_is_offline_read_only_and_does_not_consult_other_sources(self):
        destinations = {module: self.ensure(module) for module in self.modules}
        before = {
            str(path): path.stat().st_mtime_ns
            for destination in destinations.values()
            for path in destination.rglob("*")
            if path.is_file()
        }
        for module in self.modules:
            self.environment[module.SOURCE_ENV] = str(self.base / "missing-source")
        with patch.object(plugins.manager, "_materialize", side_effect=AssertionError("must remain offline")):
            for module in self.modules:
                self.assertEqual(self.ensure(module, verify_only=True), destinations[module])
        after = {
            str(path): path.stat().st_mtime_ns
            for destination in destinations.values()
            for path in destination.rglob("*")
            if path.is_file()
        }
        self.assertEqual(before, after)

    def test_dirty_tracked_untracked_and_ignored_cache_is_preserved_for_every_action(self):
        for module in self.modules:
            destination = self.ensure(module)
            for filename in ("Package.swift", "untracked.txt", "ignored.txt"):
                path = destination / filename
                before = path.read_bytes() if path.exists() else None
                path.write_text("preserve dirty cache")
                for action in ({}, {"update": True}, {"verify_only": True}):
                    with self.subTest(dependency=module.LAYOUT.name, file=filename, action=action):
                        with self.assertRaises(module.DependencyError):
                            self.ensure(module, **action)
                        self.assertEqual(path.read_text(), "preserve dirty cache")
                if before is None:
                    path.unlink()
                else:
                    path.write_bytes(before)

    def test_cross_dependency_marker_and_foreign_head_are_not_accepted_or_reset(self):
        for module in self.modules:
            destination = self.ensure(module)
            marker = destination / ".git" / module.MARKER
            original_marker = marker.read_bytes()
            other = kit if module is plugins else plugins
            foreign = marker.with_name(other.MARKER)
            marker.rename(foreign)
            with self.assertRaises(module.DependencyError):
                self.ensure(module, update=True)
            self.assertEqual(foreign.read_bytes(), original_marker)
            foreign.rename(marker)
            self.git(destination, "config", "user.email", "fixture@example.invalid")
            self.git(destination, "config", "user.name", "Managed dependency fixture")
            (destination / "Package.swift").write_text("// user-owned newer commit\n")
            self.git(destination, "add", ".")
            self.git(destination, "commit", "--quiet", "-m", "user change")
            actual = self.git(destination, "rev-parse", "HEAD")
            with self.assertRaises(module.DependencyError):
                self.ensure(module, update=True)
            self.assertEqual(self.git(destination, "rev-parse", "HEAD"), actual)

    def test_unmanaged_and_symlink_destinations_or_metadata_are_preserved(self):
        for module in self.modules:
            destination = self.root / module.CACHE_PATH
            destination.mkdir(parents=True)
            note = destination / "user.txt"
            note.write_text("preserve unmanaged directory")
            with self.assertRaises(module.DependencyError):
                self.ensure(module, update=True)
            self.assertEqual(note.read_text(), "preserve unmanaged directory")
            note.unlink()
            destination.rmdir()
            destination.symlink_to(self.sources[module], target_is_directory=True)
            with self.assertRaises(module.DependencyError):
                self.ensure(module, update=True)
            self.assertTrue(destination.is_symlink())
            destination.unlink()
            destination = self.ensure(module)
            marker = destination / ".git" / module.MARKER
            content = marker.read_bytes()
            outside = self.base / f"{module.LAYOUT.name}-outside.json"
            outside.write_bytes(content)
            marker.unlink()
            marker.symlink_to(outside)
            with self.assertRaises(module.DependencyError):
                self.ensure(module, verify_only=True)
            self.assertTrue(marker.is_symlink())
            marker.unlink()
            marker.write_bytes(content)
            git_dir = destination / ".git"
            moved = destination / ".git-preserved"
            git_dir.rename(moved)
            git_dir.symlink_to(moved, target_is_directory=True)
            with self.assertRaises(module.DependencyError):
                self.ensure(module, update=True)
            self.assertTrue(git_dir.is_symlink())

    def test_symlinked_parent_and_advisory_lock_do_not_touch_outside_files(self):
        outside = self.base / "outside"
        outside.mkdir()
        build = self.root / "build"
        build.symlink_to(outside, target_is_directory=True)
        for module in self.modules:
            with self.assertRaises(module.DependencyError):
                self.ensure(module)
        self.assertEqual(list(outside.iterdir()), [])
        build.unlink()
        parent = self.root / "build/seed"
        parent.mkdir(parents=True)
        external_lock = outside / "user-lock"
        external_lock.write_text("preserve unrelated lock")
        for module in self.modules:
            lock = parent / f".{module.LAYOUT.name}.lock"
            lock.symlink_to(external_lock)
            with self.assertRaises(module.DependencyError):
                self.ensure(module)
            self.assertTrue(lock.is_symlink())
            self.assertEqual(external_lock.read_text(), "preserve unrelated lock")
            lock.unlink()

    def test_missing_commit_keeps_previous_materialization_and_cleans_only_stage(self):
        for module in self.modules:
            destination = self.ensure(module)
            before = self.git(destination, "rev-parse", "HEAD")
            self.specs[module]["revision"] = "a" * 40
            self.write_lock(module)
            with self.assertRaises(module.DependencyError):
                self.ensure(module, update=True)
            self.assertEqual(self.git(destination, "rev-parse", "HEAD"), before)
            self.assertFalse(list(destination.parent.glob(f".{module.LAYOUT.name}-stage-*")))
            self.assertFalse(list(destination.parent.glob(f".{module.LAYOUT.name}-previous-*")))

    def test_explicit_update_rollback_after_rename_failure_is_atomic(self):
        original_rename = Path.rename
        for module in self.modules:
            destination = self.ensure(module)
            first = self.git(destination, "rev-parse", "HEAD")
            self.advance(module)
            with self.assertRaises(module.DependencyError):
                self.ensure(module)

            def fail_stage(path, target):
                if path.name.startswith(f".{module.LAYOUT.name}-stage-") and Path(target) == destination:
                    raise OSError("injected stage publication failure")
                return original_rename(path, target)

            with patch.object(Path, "rename", autospec=True, side_effect=fail_stage):
                with self.assertRaisesRegex(OSError, "injected stage publication failure"):
                    self.ensure(module, update=True)
            self.assertEqual(self.git(destination, "rev-parse", "HEAD"), first)
            self.assertFalse(list(destination.parent.glob(f".{module.LAYOUT.name}-stage-*")))
            self.assertFalse(list(destination.parent.glob(f".{module.LAYOUT.name}-previous-*")))
            self.assertEqual(
                self.git(self.ensure(module, update=True), "rev-parse", "HEAD"), self.specs[module]["revision"]
            )

    def test_user_change_during_acquisition_is_preserved_for_both(self):
        for module in self.modules:
            destination = self.ensure(module)
            first = self.git(destination, "rev-parse", "HEAD")
            self.advance(module)
            original = module._materialize

            def acquire(*args):
                stage = original(*args)
                (destination / "user.txt").write_text("changed during acquisition")
                return stage

            with patch.object(module, "_materialize", side_effect=acquire):
                with self.assertRaises(module.DependencyError):
                    self.ensure(module, update=True)
            self.assertEqual((destination / "user.txt").read_text(), "changed during acquisition")
            self.assertEqual(self.git(destination, "rev-parse", "HEAD"), first)
            self.assertFalse(list(destination.parent.glob(f".{module.LAYOUT.name}-stage-*")))

    def test_parallel_initialization_uses_independent_locks_and_correct_sources(self):
        requests = [plugins, kit, plugins, kit]
        with ThreadPoolExecutor(max_workers=4) as workers:
            destinations = list(workers.map(self.ensure, requests))
        self.assertEqual(destinations[0], destinations[2])
        self.assertEqual(destinations[1], destinations[3])
        self.assertNotEqual(destinations[0], destinations[1])
        for module in self.modules:
            destination = self.root / module.CACHE_PATH
            self.assertEqual(self.git(destination, "rev-parse", "HEAD"), self.specs[module]["revision"])
            self.assertTrue((destination.parent / f".{module.LAYOUT.name}.lock").is_file())
            self.assertFalse(list(destination.parent.glob(f".{module.LAYOUT.name}-stage-*")))

    def test_source_override_conflict_and_legacy_acquisition_are_independent(self):
        for module in self.modules:
            self.environment[module.LEGACY_SOURCE_ENV] = str(self.base / "different-source")
            with self.assertRaises(module.DependencyError):
                self.ensure(module)
            self.environment[module.LEGACY_SOURCE_ENV] = self.environment.pop(module.SOURCE_ENV)
            self.assertEqual(self.ensure(module), self.root / module.CACHE_PATH)

    def test_git_process_environment_cannot_redirect_dependency_operations(self):
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY"):
            self.environment[name] = str(self.base / "must-not-be-touched")
        for module in self.modules:
            destination = self.ensure(module)
            self.assertEqual(self.git(destination, "rev-parse", "HEAD"), self.specs[module]["revision"])
        self.assertFalse((self.base / "must-not-be-touched").exists())
