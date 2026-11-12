from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from configs import surface_delivery_index as delivery  # noqa: E402


def builder(commit, contents="first"):
    def build(path):
        path.mkdir()
        manifest = {
            "source_commit": commit,
            "surface_control_contract": "1.3",
            "surface_control_sdk": "1.3.0",
            "surface_plugins_revision": "c" * 40,
            "profile_id": "test.mock",
            "profile_version": "1.3",
        }
        (path / "manifest.json").write_text(json.dumps(manifest))
        (path / "complete.txt").write_text(contents)
        return manifest

    return build


class SurfaceDeliveryIndexTests(unittest.TestCase):
    def test_rebuild_replaces_key_and_complete_directory_preserving_other_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, first, _ = delivery.publish(root, builder("a" * 40))
            delivery.publish(root, builder("b" * 40), host="xtouch")
            delivery.publish(root, builder("a" * 40, "replacement"))
            index = delivery.read_index(root)
            self.assertEqual(len(index["deliveries"]), 2)
            self.assertEqual([entry["host"] for entry in index["deliveries"]], ["bcr2000", "xtouch"])
            self.assertEqual((first / "complete.txt").read_text(), "replacement")
            self.assertEqual(
                sorted(path.name for path in root.iterdir()),
                ["INDEX.json", "bcr2000-surface-1.3-aaaaaaa", "xtouch-surface-1.3-bbbbbbb"],
            )

    def test_malformed_duplicate_index_and_full_commit_collision_preserve_original(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, original, _ = delivery.publish(root, builder("a" * 40))
            valid = (root / "INDEX.json").read_bytes()
            for invalid in (
                b"{broken",
                b'{"schema_version":1,"deliveries":[{}]}',
                b'{"schema_version":1,"deliveries":[],"unknown":NaN}',
                b'{"schema_version":1,"deliveries":[],"deliveries":[]}',
            ):
                (root / "INDEX.json").write_bytes(invalid)
                with self.assertRaises((ValueError, KeyError)):
                    delivery.publish(root, builder("a" * 40, "must not replace"))
                self.assertEqual((root / "INDEX.json").read_bytes(), invalid)
                self.assertEqual((original / "complete.txt").read_text(), "first")
            bad_sdk = json.loads(valid)
            bad_sdk["deliveries"][0]["sdk_version"] = "future"
            (root / "INDEX.json").write_text(json.dumps(bad_sdk))
            with self.assertRaisesRegex(ValueError, "identity/hash"):
                delivery.publish(root, builder("a" * 40))
            self.assertEqual((original / "complete.txt").read_text(), "first")
            value = json.loads(valid)
            value["deliveries"].append(value["deliveries"][0].copy())
            (root / "INDEX.json").write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                delivery.publish(root, builder("b" * 40))
            (root / "INDEX.json").write_bytes(valid)
            with self.assertRaisesRegex(ValueError, "different full source commit"):
                delivery.publish(root, builder("aaaaaaa" + "b" * 33))
            self.assertEqual((root / "INDEX.json").read_bytes(), valid)
            self.assertEqual((original / "complete.txt").read_text(), "first")

    def test_index_write_failure_restores_old_directory_and_index(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, original, _ = delivery.publish(root, builder("a" * 40))
            before = (root / "INDEX.json").read_bytes()
            with patch.object(delivery, "write_index", side_effect=OSError("injected write failure")):
                with self.assertRaisesRegex(OSError, "injected"):
                    delivery.publish(root, builder("a" * 40, "must roll back"))
            self.assertEqual((root / "INDEX.json").read_bytes(), before)
            self.assertEqual((original / "complete.txt").read_text(), "first")
            self.assertFalse((root / ".index.lock").exists())
            self.assertFalse(list(root.glob(".surface-build-*")))

    def test_failed_first_index_write_leaves_no_partial_delivery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(delivery, "write_index", side_effect=OSError("index failure")):
                with self.assertRaises(OSError):
                    delivery.publish(root, builder("a" * 40))
            self.assertEqual(list(root.iterdir()), [])

    def test_failed_restore_preserves_backup_for_operator_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            delivery.publish(root, builder("a" * 40))
            before = (root / "INDEX.json").read_bytes()
            replace = delivery.os.replace

            def fail_restore(source, destination):
                if Path(source).name == "previous":
                    raise OSError("restore unavailable")
                return replace(source, destination)

            with (
                patch.object(delivery, "write_index", side_effect=OSError("index failure")),
                patch.object(delivery.os, "replace", side_effect=fail_restore),
            ):
                with self.assertRaisesRegex(RuntimeError, "previous delivery preserved"):
                    delivery.publish(root, builder("a" * 40, "must not lose original"))
            backups = list(root.glob(".surface-build-*/previous/complete.txt"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), "first")
            self.assertEqual((root / "INDEX.json").read_bytes(), before)

    def test_failed_build_leaves_no_index_or_delivery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def fail(path):
                path.mkdir()
                (path / "partial").write_text("must not publish")
                raise RuntimeError("incomplete build")

            with self.assertRaisesRegex(RuntimeError, "incomplete"):
                delivery.publish(root, fail)
            self.assertEqual(list(root.iterdir()), [])

    def test_contention_never_removes_another_owners_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / ".index.lock"
            lock.mkdir()
            (lock / "owner.json").write_text('{"pid":0,"token":"someone else"}')
            with self.assertRaises(TimeoutError):
                delivery.publish(root, builder("a" * 40), lock_timeout=0.02)
            self.assertEqual(json.loads((lock / "owner.json").read_text())["token"], "someone else")
            self.assertFalse((root / "INDEX.json").exists())

    def test_release_does_not_remove_a_replaced_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with delivery.index_lock(root):
                lock = root / ".index.lock"
                lock.rename(root / "original-lock")
                lock.mkdir()
                (lock / "owner.json").write_text('{"token":"successor"}')
            self.assertEqual(json.loads((lock / "owner.json").read_text())["token"], "successor")

    def test_two_real_process_publishers_preserve_both_entries(self):
        code = """
import json, sys, time
from pathlib import Path
from configs.surface_delivery_index import publish
root, host, commit = sys.argv[1:]
def build(path):
    path.mkdir()
    value = {'source_commit': commit, 'surface_control_contract': '1.3', 'surface_control_sdk': '1.3.0',
             'surface_plugins_revision': 'c'*40, 'profile_id': 'test.mock', 'profile_version': '1.3'}
    (path/'manifest.json').write_text(json.dumps(value))
    time.sleep(0.05)
    return value
publish(Path(root), build, host=host)
"""
        with tempfile.TemporaryDirectory() as temporary:
            processes = [
                subprocess.Popen(
                    [sys.executable, "-c", code, temporary, host, commit],
                    cwd=ROOT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                for host, commit in (("bcr2000", "a" * 40), ("xtouch", "b" * 40))
            ]
            for process in processes:
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, (stdout, stderr))
            self.assertEqual(len(delivery.read_index(Path(temporary))["deliveries"]), 2)
