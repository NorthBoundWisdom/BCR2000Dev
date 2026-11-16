from copy import deepcopy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

from configs import package_provider, prepare_f_candidate_attended, surface_sdk_metadata as metadata

ROOT = Path(__file__).resolve().parents[2]
OLD_FIXTURE = ROOT / "Tests/Fixtures/SurfaceSDK/surface-control-sdk-1.4.0.zip"
OLD_SHA256 = "c277eb0a78c2dc165aac7ab0384c00853376bf119df5906f65d8e724c6a9423e"
OLD_REVISION = "12ba0edbc1f2c46eea5311f9b8f982d563c55b75"
NEW_REVISION = "5ffbac79699505a76298172e8e6f28f7de3df88b"


class SurfaceSDKMetadataTests(unittest.TestCase):
    def current_zip(self, root):
        shared = ROOT / "build/seed/SurfacePlugins/clients/python"
        output = root / "surface-control-sdk-1.5.0.zip"
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for package in (
                "surface_control",
                "surface_conformance",
                "surface_control_diagnostics",
                "surface_panel_demo",
            ):
                for path in sorted((shared / package).rglob("*")):
                    if path.is_file() and path.suffix in (".py", ".md", ".json"):
                        archive.write(path, str(path.relative_to(shared)))
        return output

    def sidecar(self, root, version):
        if version == "1.4.0":
            shutil.copy2(OLD_FIXTURE, root / "surface-control-sdk-1.4.0.zip")
        else:
            self.current_zip(root)
        value = metadata.create(root, version, OLD_REVISION if version == "1.4.0" else NEW_REVISION)
        path = root / metadata.METADATA_NAME
        path.write_text(json.dumps(value))
        return path, value

    def test_frozen_real_sdk14_bytes_and_current15_are_both_explicitly_supported(self):
        self.assertEqual(hashlib.sha256(OLD_FIXTURE.read_bytes()).hexdigest(), OLD_SHA256)
        reference = json.loads((OLD_FIXTURE.parent / "REFERENCE.json").read_text())
        self.assertEqual(reference["source_revision"], OLD_REVISION)
        with zipfile.ZipFile(OLD_FIXTURE) as archive:
            self.assertEqual(metadata.embedded_version(archive), "1.4.0")
            self.assertEqual(
                {name: hashlib.sha256(archive.read(name)).hexdigest() for name in archive.namelist()},
                reference["members_sha256"],
            )
        for version in ("1.4.0", "1.5.0"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path, value = self.sidecar(root, version)
                self.assertEqual(metadata.load(path), value)
                plan = prepare_f_candidate_attended.plan(value["sdk_zip"])
                self.assertFalse(plan["hardware_qualified"])
                self.assertFalse(plan["automatic_promotion"])
                self.assertTrue(any(value["sdk_zip"] in row["command"] for row in plan["steps"]))
                result = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "configs/prepare_f_candidate_attended.py"),
                        "--sdk-manifest",
                        str(path),
                        "--output",
                        str(root / "attended"),
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["hardware_executed"], 0)

    def test_unknown_versions_names_source_shape_and_escaping_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, good = self.sidecar(root, "1.5.0")
            for field, value in [
                ("sdk_version", "1.6.0"),
                ("sdk_version", "../1.5.0"),
                ("sdk_zip", "../surface-control-sdk-1.5.0.zip"),
                ("sdk_zip", "/tmp/surface-control-sdk-1.5.0.zip"),
                ("sdk_zip", "renamed.zip"),
                ("surface_plugins_revision", "5ff"),
                ("sdk_sha256", "0" * 64),
                ("schema_version", True),
            ]:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    changed = deepcopy(good)
                    changed[field] = value
                    metadata.validate(changed, root)

    def test_wrong_embedded_version_duplicate_member_or_runtime_test_fixture_is_rejected(self):
        for mutation in ("old-version", "duplicate", "traversal", "test-fixture", "nested-test-fixture"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                if mutation == "old-version":
                    shutil.copy2(OLD_FIXTURE, root / "surface-control-sdk-1.5.0.zip")
                else:
                    path = self.current_zip(root)
                    with zipfile.ZipFile(path, "a") as archive:
                        if mutation == "duplicate":
                            archive.writestr("surface_control/__init__.py", archive.read("surface_control/__init__.py"))
                        elif mutation == "traversal":
                            archive.writestr("../escaped.py", "")
                        elif mutation == "test-fixture":
                            archive.writestr("surface_control/sdk_1_4_0.py", "")
                        else:
                            archive.writestr("surface_control/tests/fixtures/sdk_1_4_0.py", "")
                with self.assertRaises(ValueError):
                    metadata.create(root, "1.5.0", NEW_REVISION)

    def test_sidecar_and_final_manifest_must_agree_even_when_individually_valid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path, value = self.sidecar(root, "1.5.0")
            manifest = {
                "surface_control_sdk": "1.5.0",
                "surface_plugins_revision": NEW_REVISION,
                "surface_plugins_materialized_revision": NEW_REVISION,
                "files_sha256": {
                    value["sdk_zip"]: value["sdk_sha256"],
                    metadata.METADATA_NAME: hashlib.sha256(path.read_bytes()).hexdigest(),
                },
            }
            self.assertEqual(metadata.verify_manifest(root, manifest)[1], "1.5.0")
            for field in ("surface_plugins_revision", "surface_plugins_materialized_revision"):
                with self.subTest(field=field), self.assertRaises(ValueError):
                    wrong = deepcopy(manifest)
                    wrong[field] = "1" * 40
                    metadata.verify_manifest(root, wrong)
            old = deepcopy(manifest)
            old["surface_control_sdk"] = "1.4.0"
            shutil.copy2(OLD_FIXTURE, root / "surface-control-sdk-1.4.0.zip")
            old["files_sha256"]["surface-control-sdk-1.4.0.zip"] = OLD_SHA256
            with self.assertRaises(ValueError):
                metadata.verify_manifest(root, old)

    def test_legacy14_artifact_without_new_sidecar_is_retained_and_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copy2(OLD_FIXTURE, root / "surface-control-sdk-1.4.0.zip")
            manifest = {"surface_control_sdk": "1.4.0", "files_sha256": {"surface-control-sdk-1.4.0.zip": OLD_SHA256}}
            self.assertEqual(metadata.verify_manifest(root, manifest)[1], "1.4.0")
            sidecar, _ = self.sidecar(root, "1.5.0")
            link = root / "linked" / metadata.METADATA_NAME
            link.parent.mkdir()
            link.symlink_to(sidecar)
            with self.assertRaises(ValueError):
                metadata.load(link)

    def test_packager_default_contract_and_old_schema_bytes_remain_explicit(self):
        self.assertEqual(package_provider.SURFACE_CONTRACT, "1.3")
        self.assertEqual(package_provider.SURFACE_SDK, "1.5.0")
        self.assertIn("surface-control-diagnostic-capture.schema.json", package_provider.SURFACE_FILES)
        self.assertIn("surface-control-diagnostic-capture-v1.5.schema.json", package_provider.SURFACE_FILES)
        for suffix in ("tools", "examples", "hardware-tools", "hardware-examples"):
            self.assertIn("surface-control-input-retention-" + suffix + ".json", package_provider.SURFACE_FILES)
