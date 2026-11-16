"""The exact packaged checker selects verified SDK1.4/1.5 without editing its mode checks."""

import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

from Support.NativeDiagnostics import verify_status_panel_demo as checker
from configs import surface_sdk_metadata

ROOT = Path(__file__).resolve().parents[2]
OLD = ROOT / "Tests/Fixtures/SurfaceSDK/surface-control-sdk-1.4.0.zip"
OLD_SHA = "c277eb0a78c2dc165aac7ab0384c00853376bf119df5906f65d8e724c6a9423e"


class StatusPanelSDKSelectionTests(unittest.TestCase):
    def artifact(self, directory, version):
        sdk = directory / f"surface-control-sdk-{version}.zip"
        if version == "1.4.0":
            shutil.copy2(OLD, sdk)
        else:
            shared = ROOT / "build/seed/SurfacePlugins/clients/python"
            with zipfile.ZipFile(sdk, "w") as archive:
                for package in (
                    "surface_control",
                    "surface_conformance",
                    "surface_control_diagnostics",
                    "surface_panel_demo",
                ):
                    for path in sorted((shared / package).rglob("*")):
                        if path.is_file() and path.suffix in (".py", ".md", ".json"):
                            archive.write(path, str(path.relative_to(shared)))
        revision = (
            "12ba0edbc1f2c46eea5311f9b8f982d563c55b75"
            if version == "1.4.0"
            else "5ffbac79699505a76298172e8e6f28f7de3df88b"
        )
        manifest = {
            "surface_control_sdk": version,
            "surface_plugins_revision": revision,
            "surface_plugins_materialized_revision": revision,
            "files_sha256": {sdk.name: hashlib.sha256(sdk.read_bytes()).hexdigest()},
        }
        if version == "1.5.0":
            sidecar = directory / surface_sdk_metadata.METADATA_NAME
            sidecar.write_text(json.dumps(surface_sdk_metadata.create(directory, version, revision)))
            manifest["files_sha256"][sidecar.name] = hashlib.sha256(sidecar.read_bytes()).hexdigest()
        (directory / "manifest.json").write_text(json.dumps(manifest))
        return sdk, manifest

    def test_real_frozen14_and_actual_current15_are_selected_by_the_same_checker(self):
        self.assertEqual(hashlib.sha256(OLD.read_bytes()).hexdigest(), OLD_SHA)
        for version in ("1.4.0", "1.5.0"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                sdk, _ = self.artifact(root, version)
                self.assertEqual(checker.verified_sdk(root), (sdk, version))

    def test_unknown_version_wrong_embedded_sdk_and_unpinned_resources_fail_before_import(self):
        for mutation in ("version", "embedded", "hash"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                sdk, manifest = self.artifact(root, "1.5.0")
                if mutation == "version":
                    manifest["surface_control_sdk"] = "1.6.0"
                elif mutation == "embedded":
                    shutil.copy2(OLD, sdk)
                    manifest["files_sha256"][sdk.name] = OLD_SHA
                else:
                    sdk.write_bytes(b"changed")
                (root / "manifest.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    checker.verified_sdk(root)

    def test_relative_escape_symlink_and_sidecar_disagreement_are_rejected(self):
        for mutation in ("escape", "symlink", "sidecar"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                sdk, manifest = self.artifact(root, "1.5.0")
                if mutation == "escape":
                    manifest["files_sha256"]["../foreign"] = "0" * 64
                elif mutation == "symlink":
                    target = root / "copy.zip"
                    sdk.rename(target)
                    sdk.symlink_to(target)
                else:
                    manifest["surface_plugins_revision"] = "1" * 40
                (root / "manifest.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    checker.verified_sdk(root)

    def test_canonical_shared_helper_is_the_one_shipped_in_diagnostics(self):
        from Support.NativeDiagnostics import surface_sdk_metadata as shipped

        self.assertIs(surface_sdk_metadata.verify_manifest, shipped.verify_manifest)
        self.assertIs(checker.verify_manifest, shipped.verify_manifest)
