from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from configs.app_build import load_app_build_settings
from configs.build_environment import ensure_local_build_environment, load_build_environment
from configs.ci_release import release_version, validate_assets
from configs import macos_workflow, setup_local_project, source_root_workflow
from configs._vendor.freecm.errors import RepoCommandManifestError
from configs._vendor.freecm.repo_commands import validate_repo_command_manifest

REPO_ROOT = Path(__file__).resolve().parents[2]


class BuildConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / "configs").mkdir()
        (self.root / "configs/app_build.json").write_text(json.dumps({"MARKETING_VERSION": "0.1.0", "ARCHIVE_ID": "1"}))
        (self.root / "configs/build.local.example.json").write_text('{"environment": {}, "path": []}\n')
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_setup_preserves_existing_local_settings(self):
        self.assertTrue(ensure_local_build_environment(self.root))
        local = self.root / "build.local.json"
        original = '{"environment":{"MARKETING_VERSION":"2.3.4","ARCHIVE_ID":"42"},"path":[]}'
        local.write_text(original)
        self.assertFalse(ensure_local_build_environment(self.root))
        self.assertEqual(local.read_text(), original)
        self.assertEqual(load_app_build_settings(self.root), {"MARKETING_VERSION": "2.3.4", "ARCHIVE_ID": "42"})

    def test_ci_environment_overrides_machine_local_version(self):
        (self.root / "build.local.json").write_text('{"environment":{"MARKETING_VERSION":"2.3.4"}}')
        os.environ["MARKETING_VERSION"] = "3.0.0"
        self.assertEqual(load_app_build_settings(self.root)["MARKETING_VERSION"], "3.0.0")

    def test_config_refreshes_readiness_marker_without_overwriting_local_settings(self):
        (self.root / "configs/freecm.commands.jsonc").write_text(
            (REPO_ROOT / "configs/freecm.commands.jsonc").read_text()
        )
        local = self.root / "build.local.json"
        original = '{"environment":{"MARKETING_VERSION":"2.3.4"},"path":[]}'
        local.write_text(original)
        marker = self.root / "build/configured.json"
        marker.parent.mkdir()
        marker.write_text("old configuration")
        os.utime(marker, (1, 1))
        with patch.object(setup_local_project, "REPO_ROOT", self.root), patch.object(setup_local_project.subprocess, "run"):
            self.assertEqual(setup_local_project.main(), 0)
        self.assertEqual(local.read_text(), original)
        self.assertGreater(marker.stat().st_mtime, 1)
        self.assertEqual(json.loads(marker.read_text())["app_build"]["MARKETING_VERSION"], "2.3.4")

    def test_invalid_versions_cannot_escape_artifact_directory(self):
        for value in ("../../outside", "1.0.0/other", "1.0.0\n", "1.0.0;command", "v1.0.0", 1):
            with self.subTest(value=value):
                (self.root / "configs/app_build.json").write_text(json.dumps({"MARKETING_VERSION": value, "ARCHIVE_ID": "1"}))
                with self.assertRaises(ValueError):
                    load_app_build_settings(self.root)

    def test_build_number_must_be_positive_integer_string(self):
        for value in ("0", "-1", "1.2", "١", "1\n", 1):
            with self.subTest(value=value):
                os.environ["ARCHIVE_ID"] = str(value) if value != 1 else ""
                with self.assertRaises(ValueError):
                    load_app_build_settings(self.root)

    def test_local_paths_expand_without_shell_execution(self):
        (self.root / "build.local.json").write_text(json.dumps({"environment": {"SDK": "${REPO_ROOT}/sdk"}, "path": ["$SDK/bin"]}))
        environment = load_build_environment(self.root, environ={"PATH": "/usr/bin"})
        self.assertEqual(environment["PATH"], f"{self.root}/sdk/bin:/usr/bin")

    def test_local_variable_cycles_and_unknown_fields_are_visible(self):
        for payload in ({"environment": {"A": "$B", "B": "$A"}}, {"commands": ["anything"]}):
            with self.subTest(payload=payload):
                (self.root / "build.local.json").write_text(json.dumps(payload))
                with self.assertRaises(ValueError):
                    load_build_environment(self.root, environ={})


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.assets = []
        for extension in ("zip", "dmg"):
            asset = self.root / f"BCRAgentConsole_v1.2.3_1_macOS_universal_ad-hoc.{extension}"
            asset.write_bytes(b"release payload")
            proof = {"schema_version": 1, "asset": asset.name, "version": "1.2.3", "build": "1", "commit": "commit-a", "dirty": False, "architecture": "universal", "signature": "ad-hoc", "notarized": False, "sha256": macos_workflow._sha(asset)}
            asset.with_suffix(asset.suffix + ".build.json").write_text(json.dumps(proof))
            self.assets.append(asset)

    def test_complete_release_produces_checksums(self):
        validate_assets(self.root, "v1.2.3", "commit-a")
        checksums = (self.root / "SHA256SUMS").read_text()
        self.assertEqual(len(checksums.splitlines()), 2)
        self.assertIn(self.assets[0].name, checksums)
        self.assertIn(self.assets[1].name, checksums)

    def test_modified_download_is_rejected_before_extraction(self):
        self.assets[0].write_bytes(b"modified download")
        with patch.object(macos_workflow, "_run") as command:
            with self.assertRaisesRegex(ValueError, "hash/provenance"):
                macos_workflow.check_package(self.assets[0])
            command.assert_not_called()
        with self.assertRaisesRegex(ValueError, "provenance/hash"):
            validate_assets(self.root, "1.2.3", "commit-a")

    def test_wrong_commit_dirty_tree_and_false_architecture_block_release(self):
        proof_path = self.assets[0].with_suffix(".zip.build.json")
        original = json.loads(proof_path.read_text())
        for key, value in (("commit", "commit-b"), ("dirty", True), ("architecture", "arm64"), ("notarized", True)):
            with self.subTest(key=key):
                proof_path.write_text(json.dumps({**original, key: value}))
                with self.assertRaisesRegex(ValueError, "provenance/hash"):
                    validate_assets(self.root, "1.2.3", "commit-a")

    def test_missing_or_stale_release_assets_block_release(self):
        stale = self.root / "old-release.zip"
        stale.touch()
        with self.assertRaisesRegex(ValueError, "exactly"):
            validate_assets(self.root, "1.2.3", "commit-a")
        stale.unlink()
        self.assets[0].unlink()
        with self.assertRaisesRegex(ValueError, "exactly"):
            validate_assets(self.root, "1.2.3", "commit-a")

    def test_tag_validation_rejects_invalid_or_injected_versions(self):
        self.assertEqual(release_version("v1.2.3"), "1.2.3")
        for value in ("", "v1.2", "v1.2.3\nother=1", "1.2.3/other", "01.2.3", "1.2.3-rc.1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release_version(value)

    def test_developer_id_requires_notary_profile_before_build(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(macos_workflow, "build") as build:
            with self.assertRaisesRegex(ValueError, "notary"):
                macos_workflow.package(distribution="developer-id")
            build.assert_not_called()

    def test_rejected_notarization_never_looks_successful(self):
        with patch.object(macos_workflow, "_run", return_value='{"id":"submission", "status":"Invalid"}'):
            with self.assertRaisesRegex(RuntimeError, "Notarization failed"):
                macos_workflow._notarize(Path("app.zip"), "test-profile")

    def test_ambiguous_signing_identity_is_rejected(self):
        identities = '  1) AAA "Developer ID Application: One (TEAMONE)"\n  2) BBB "Developer ID Application: Two (TEAMTWO)"'
        with patch.dict(os.environ, {}, clear=True), patch.object(macos_workflow, "_run", return_value=identities):
            with self.assertRaisesRegex(ValueError, "exactly one"):
                macos_workflow._sign(Path("app.app"), "developer-id", None)


class PluginAndCleanupTests(unittest.TestCase):
    def test_plugin_manifest_validates_without_freecm_checkout(self):
        self.assertFalse((REPO_ROOT / "FreeCM").exists())
        summary = validate_repo_command_manifest(REPO_ROOT)
        self.assertEqual(summary.configuration_count, 3)
        self.assertGreaterEqual(summary.variant_count, 10)

    def test_dangling_plugin_default_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "configs").mkdir()
            document = json.loads((REPO_ROOT / "configs/freecm.commands.jsonc").read_text())
            document["commands"]["config"][0]["defaults"]["package"] = "missing-package"
            (root / "configs/freecm.commands.jsonc").write_text(json.dumps(document))
            with self.assertRaises(RepoCommandManifestError):
                validate_repo_command_manifest(root)

    def test_cleanup_preserves_runtime_data_and_retired_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("app", "swiftpm", "retired-FreeCM", "codex"):
                (root / "build" / name).mkdir(parents=True)
            with patch.object(source_root_workflow, "REPO_ROOT", root):
                source_root_workflow.main(["--cleanbuild", "--dry-run"])
                self.assertTrue((root / "build/app").exists())
                source_root_workflow.main(["--cleanbuild"])
            self.assertFalse((root / "build/app").exists())
            self.assertTrue((root / "build/retired-FreeCM").exists())
            self.assertTrue((root / "build/codex").exists())

    def test_cleanup_refuses_symlinked_build_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            external = root / "external"
            external.mkdir()
            (root / "build").symlink_to(external, target_is_directory=True)
            with patch.object(source_root_workflow, "REPO_ROOT", root):
                with self.assertRaisesRegex(ValueError, "symlinked"):
                    source_root_workflow.main(["--cleanbuild"])
            self.assertTrue(external.exists())


if __name__ == "__main__":
    unittest.main()
