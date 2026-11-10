from datetime import datetime, timedelta, timezone
import json
import os
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from configs import ci_signing, driverkit_release, macos_workflow
from configs.ci_release import validate_assets


class ReleaseSigningTests(unittest.TestCase):
    def profile(self, driver=True):
        bundle = driverkit_release.DRIVER_ID if driver else driverkit_release.HOST_ID
        ent = {
            "com.apple.application-identifier": "TEAMID1234." + bundle,
            "com.apple.developer.team-identifier": "TEAMID1234",
        }
        ent.update(
            {"com.apple.developer.driverkit": True, driverkit_release.USB_ENTITLEMENT: [{"idVendor": 0x1397}]}
            if driver
            else {"com.apple.developer.system-extension.install": True}
        )
        return {
            "UUID": "00000000-0000-4000-8000-000000000001",
            "TeamIdentifier": ["TEAMID1234"],
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1),
            "ProvisionsAllDevices": True,
            "Entitlements": ent,
        }

    def test_exact_developer_id_profiles_are_accepted(self):
        for driver in (True, False):
            bundle = driverkit_release.DRIVER_ID if driver else driverkit_release.HOST_ID
            self.assertEqual(
                driverkit_release.validate_profile(self.profile(driver), bundle, driver=driver), "TEAMID1234"
            )

    def test_development_profiles_wildcards_and_debug_grants_block_release(self):
        original = self.profile()
        cases = [
            dict(original, ProvisionedDevices=[]),
            dict(original, ProvisionsAllDevices=False),
            dict(original, ExpirationDate=datetime.now(timezone.utc) - timedelta(days=1)),
        ]
        for updates in (
            {"get-task-allow": True},
            {"com.apple.security.get-task-allow": True},
            {driverkit_release.USB_ENTITLEMENT: [{"idVendor": "*"}]},
            {driverkit_release.USB_ENTITLEMENT: [{"idVendor": 0x1397, "idProduct": 1}]},
            {"com.apple.application-identifier": "TEAMID1234.*"},
        ):
            cases.append(dict(original, Entitlements=dict(original["Entitlements"], **updates)))
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                driverkit_release.validate_profile(case, driverkit_release.DRIVER_ID, driver=True)

    def test_release_configuration_is_one_byte_change_from_proven_usb_descriptor(self):
        raw = driverkit_release.ORIGINAL_CONFIGURATION
        patched, offset = driverkit_release.patch_configuration(raw)
        self.assertEqual((len(raw), offset, raw[offset], patched[offset]), (101, 91, 4, 8))
        self.assertEqual(sum(a != b for a, b in zip(raw, patched)), 1)

    def test_missing_ci_secrets_never_touch_keychain(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(ci_signing, "silent") as command:
            with self.assertRaisesRegex(ValueError, "Missing release secrets"):
                ci_signing.setup()
            command.assert_not_called()

    def test_wrapped_base64_secrets_are_supported_but_invalid_content_is_rejected(self):
        self.assertEqual(ci_signing.decode_secret("aGVs\n bG8=\r\n"), b"hello")
        with self.assertRaises(ValueError):
            ci_signing.decode_secret("not!base64")

    def test_failed_credential_command_never_reports_secret_arguments(self):
        result = type("Result", (), {"returncode": 1, "stdout": b"", "stderr": b"sensitive value"})()
        with patch.object(ci_signing.subprocess, "run", return_value=result):
            with self.assertRaises(RuntimeError) as caught:
                ci_signing.silent(["security", "import", "secret-file", "-P", "sensitive value"])
        self.assertNotIn("sensitive value", str(caught.exception))
        self.assertNotIn("secret-file", str(caught.exception))

    def test_cleanup_refuses_foreign_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "bcr-signing-state.json").write_text(json.dumps({"directory": str(root.parent), "searchList": []}))
            with patch.dict(os.environ, {"RUNNER_TEMP": str(root)}), patch.object(ci_signing, "silent") as command:
                with self.assertRaisesRegex(ValueError, "outside"):
                    ci_signing.cleanup()
                command.assert_not_called()

    def test_a_plain_developer_id_app_may_have_no_entitlements(self):
        with patch.object(driverkit_release, "run", return_value=b""):
            self.assertEqual(driverkit_release.signing_entitlements(Path("app.app")), {})

    def test_profile_grant_does_not_replace_missing_signed_host_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            host = Path(directory) / "host.app"
            driver = host / "Contents/Library/SystemExtensions" / (driverkit_release.DRIVER_ID + ".dext")
            driver.mkdir(parents=True)
            (host / "Contents/Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": driverkit_release.HOST_ID,
                        "CFBundleExecutable": "BCRDriverKitProbe",
                        "BCRProbeLabMode": False,
                        "CFBundleShortVersionString": "1.2.3",
                        "CFBundleVersion": "42",
                    }
                )
            )
            patched, _ = driverkit_release.patch_configuration(driverkit_release.ORIGINAL_CONFIGURATION)
            info = driverkit_release.info_plist("override", patched)
            info.update(CFBundleShortVersionString="1.2.3", CFBundleVersion="42")
            (driver / "Info.plist").write_bytes(plistlib.dumps(info))
            with (
                patch.object(driverkit_release, "decode_profile", side_effect=[self.profile(False), self.profile()]),
                patch.object(driverkit_release, "verify_developer_id", return_value="TEAMID1234"),
                patch.object(
                    driverkit_release,
                    "signing_entitlements",
                    return_value={"com.apple.developer.team-identifier": "TEAMID1234"},
                ),
            ):
                with self.assertRaisesRegex(ValueError, "install grant"):
                    driverkit_release.verify_companion(host, "1.2.3", "42")

    def test_companion_cannot_enter_ad_hoc_package(self):
        with patch.object(macos_workflow, "build") as build:
            with self.assertRaisesRegex(ValueError, "universal Developer ID"):
                macos_workflow.package(driverkit_host=Path("compatibility.app"))
            build.assert_not_called()

    def test_formal_release_requires_notarization_and_driverkit_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = []
            for extension in ("zip", "dmg"):
                asset = root / f"BCRAgentConsole_v1.2.3_42_macOS_universal_developer-id.{extension}"
                asset.write_bytes(b"signed payload")
                proof = {
                    "schema_version": 1,
                    "asset": asset.name,
                    "version": "1.2.3",
                    "build": "42",
                    "commit": "commit-a",
                    "dirty": False,
                    "architecture": "universal",
                    "signature": "developer-id",
                    "notarized": True,
                    "sha256": macos_workflow._sha(asset),
                }
                sidecar = asset.with_suffix(asset.suffix + ".build.json")
                sidecar.write_text(json.dumps(proof))
                assets.append(sidecar)
            with self.assertRaisesRegex(ValueError, "companion"):
                validate_assets(root, "1.2.3", "commit-a", "developer-id", "42")
            for path in assets:
                proof = json.loads(path.read_text())
                proof["driverkit"] = {
                    "host": "BCRUSBCompatibility.app",
                    "bundle_id": driverkit_release.DRIVER_ID,
                    "signature": "developer-id",
                    "supported_mode": "U-1",
                    "notarized": True,
                }
                path.write_text(json.dumps(proof))
            validate_assets(root, "1.2.3", "commit-a", "developer-id", "42")
            listed = json.loads((root / "release-assets.json").read_text())
            self.assertEqual(len(listed), 6)
            self.assertNotIn("release-assets.json", listed)

    def test_packaging_notarization_failure_writes_no_records(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(macos_workflow, "BUILD_ROOT", Path(directory)),
            patch.object(macos_workflow, "PACKAGE_ROOT", Path(directory) / "package"),
            patch.object(macos_workflow, "build", return_value=Path("app.app")),
            patch.object(macos_workflow, "smoke"),
            patch.object(macos_workflow, "_zip"),
            patch.object(macos_workflow, "_notarize", side_effect=RuntimeError("rejected")),
            patch.object(macos_workflow, "_write_records") as records,
        ):
            with self.assertRaisesRegex(RuntimeError, "rejected"):
                macos_workflow.package(distribution="developer-id", notary_profile="test-profile")
            records.assert_not_called()

    def test_disk_image_is_timestamp_signed_without_executable_runtime_flag(self):
        def command(argv, **kwargs):
            return '1) ABC "Developer ID Application: Test (TEAMID1234)"' if argv[0] == "security" else ""

        with patch.dict(os.environ, {}, clear=True), patch.object(macos_workflow, "_run", side_effect=command) as run:
            macos_workflow._sign(Path("installer.dmg"), "developer-id", "ABC", hardened=False)
        signing = [call.args[0] for call in run.call_args_list if "--force" in call.args[0]][0]
        self.assertIn("--timestamp", signing)
        self.assertNotIn("--options", signing)

    def test_formal_dmg_is_checked_before_mounting(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "release.dmg"
            image.write_bytes(b"untrusted image")
            image.with_suffix(".dmg.build.json").write_text(
                json.dumps({"asset": image.name, "sha256": macos_workflow._sha(image), "notarized": True})
            )
            with patch.object(macos_workflow, "_run", side_effect=RuntimeError("invalid signature")) as command:
                with self.assertRaisesRegex(RuntimeError, "invalid signature"):
                    macos_workflow.check_package(image)
            self.assertEqual(command.call_args.args[0][0], "codesign")
            self.assertEqual(command.call_count, 1)


if __name__ == "__main__":
    unittest.main()
