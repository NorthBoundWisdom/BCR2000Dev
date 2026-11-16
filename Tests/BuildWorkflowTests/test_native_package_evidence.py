import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from configs import macos_workflow as workflow


def proof_for(asset):
    return {
        "schema_version": 1,
        "asset": asset.name,
        "sha256": workflow._sha(asset),
        "version": "0.1.0",
        "build": "1",
        "commit": "a" * 40,
        "dirty": False,
        "architecture": "universal",
        "architectures": ["arm64", "x86_64"],
        "signature": "ad-hoc",
        "notarized": False,
        "minimum_macos": "14.0",
        "swift": "Swift fixture toolchain",
        "surface_plugins_revision": workflow.locked_plugin_revision(),
    }


def marker(mode):
    return {
        "type": "bcr.native_startup",
        "mode": mode,
        "hardwareAccessed": False,
        "windowCreated": mode == "gui",
        "firstFramePresented": mode == "gui",
        "first_frame": mode == "gui",
        "icon": True,
        "clientVersion": "0.1.0",
    }


class NativePackageEvidenceTests(unittest.TestCase):
    def test_gui_and_headless_evidence_cannot_substitute_for_each_other(self):
        for mode in ("gui", "headless"):
            record = marker(mode)
            self.assertEqual(workflow.validate_smoke("diagnostic\n" + json.dumps(record), mode=mode), record)
            with self.assertRaises(ValueError):
                workflow.validate_smoke(json.dumps(marker("headless" if mode == "gui" else "gui")), mode=mode)
            for key, value in (
                ("hardwareAccessed", True),
                ("windowCreated", mode != "gui"),
                ("firstFramePresented", mode != "gui"),
                ("first_frame", 1),
                ("icon", False),
            ):
                with self.subTest(mode=mode, key=key), self.assertRaises(ValueError):
                    workflow.validate_smoke(json.dumps({**record, key: value}), mode=mode)

    def test_invalid_provenance_is_rejected_before_extracting_any_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory) / "release.zip"
            asset.write_bytes(b"fixture")
            record = proof_for(asset)
            for key, value in (
                ("commit", "short"),
                ("dirty", "false"),
                ("architectures", ["arm64"]),
                ("minimum_macos", "13.0"),
                ("swift", ""),
                ("surface_plugins_revision", None),
                ("schema_version", True),
                ("architecture", []),
                ("signature", "unknown"),
            ):
                with self.subTest(key=key):
                    asset.with_suffix(".zip.build.json").write_text(json.dumps({**record, key: value}))
                    with patch.object(workflow, "_run") as command, self.assertRaises(ValueError):
                        workflow.check_package(asset)
                    command.assert_not_called()

    def test_zip_and_dmg_checks_use_the_final_extracted_or_copied_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            for extension in ("zip", "dmg"):
                asset = Path(directory) / ("release." + extension)
                asset.write_bytes(b"final archive")
                asset.with_suffix(asset.suffix + ".build.json").write_text(json.dumps(proof_for(asset)))
                commands = []

                def command(argv, **kwargs):
                    commands.append([str(part) for part in argv])
                    if argv[:2] == ["hdiutil", "attach"]:
                        mount = Path(argv[-1])
                        mount.mkdir()
                        (mount / "Applications").symlink_to("/Applications")
                    return ""

                with (
                    patch.object(workflow, "_run", side_effect=command),
                    patch.object(workflow, "_check_payload") as payload,
                    patch.object(workflow, "_check_companion"),
                ):
                    workflow.check_package(asset)
                checked = payload.call_args.args[0]
                self.assertNotEqual(checked, workflow.APP_BUNDLE)
                self.assertEqual(checked.name, workflow.PRODUCT + ".app")
                if extension == "zip":
                    self.assertEqual(commands[0][:3], ["ditto", "-x", "-k"])
                    self.assertEqual(commands[0][3], str(asset.resolve()))
                else:
                    self.assertIn("-readonly", commands[0])
                    self.assertEqual(commands[1][0], "ditto")
                    self.assertEqual(commands[-1][:2], ["hdiutil", "detach"])

    def test_both_startup_modes_run_only_after_bundle_provenance_matches(self):
        record = proof_for(Path(__file__))
        info = {
            "CFBundleShortVersionString": record["version"],
            "CFBundleVersion": record["build"],
            "BCRDistribution": record["signature"],
            "BCRSourceRevision": record["commit"],
            "BCRSourceTreeDirty": record["dirty"],
            "BCRSurfacePluginsRevision": record["surface_plugins_revision"],
            "LSMinimumSystemVersion": record["minimum_macos"],
        }
        modes = []
        with (
            patch.object(workflow, "verify_bundle", return_value=info),
            patch.object(workflow, "_run", return_value="arm64 x86_64"),
            patch.object(workflow.platform, "machine", return_value="arm64"),
            patch.object(workflow, "headless_smoke", side_effect=lambda _: modes.append("headless")),
            patch.object(workflow, "smoke", side_effect=lambda _: modes.append("gui")),
        ):
            workflow._check_payload(Path("Final.app"), record)
            self.assertEqual(modes, ["headless", "gui"])
            for key, value in (
                ("BCRSourceRevision", "b" * 40),
                ("BCRSourceTreeDirty", True),
                ("BCRSurfacePluginsRevision", "c" * 40),
            ):
                with (
                    self.subTest(key=key),
                    patch.object(workflow, "verify_bundle", return_value={**info, key: value}),
                    self.assertRaises(ValueError),
                ):
                    workflow._check_payload(Path("Final.app"), record)
            self.assertEqual(modes, ["headless", "gui"])

    def test_native_record_keeps_build_architecture_when_checked_on_another_host(self):
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory) / "native.zip"
            asset.write_bytes(b"fixture")
            record = {**proof_for(asset), "architecture": "native", "architectures": ["arm64"]}
            asset.with_suffix(".zip.build.json").write_text(json.dumps(record))
            with patch.object(workflow.platform, "machine", return_value="x86_64"):
                self.assertEqual(workflow.validate_package_record(asset)["architectures"], ["arm64"])

    def test_arm_package_runner_includes_runtime_diagnostics_without_an_intel_runner(self):
        source = (workflow.REPO_ROOT / ".github/workflows/release.yml").read_text()
        smoke = source.split("  package-smoke:", 1)[1].split("  verify:", 1)[0]
        self.assertIn("runs-on: macos-15", smoke)
        self.assertNotIn("matrix:", smoke)
        self.assertNotIn("macos-15-intel", source)
        self.assertNotIn("macos-26-intel", source)
        sparse = smoke.split("sparse-checkout: |", 1)[1].split("      - uses:", 1)[0]
        self.assertIn("Support/NativeDiagnostics", sparse)
        self.assertTrue((workflow.REPO_ROOT / "Support/NativeDiagnostics/diagnostic_io.py").is_file())
        self.assertIn("'check-package'", smoke)
        self.assertNotIn("continue-on-error", smoke)

    def test_manual_release_dispatch_cannot_publish(self):
        source = (workflow.REPO_ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')", source)
        self.assertIn("GUI and headless startup from final ZIP", source)
