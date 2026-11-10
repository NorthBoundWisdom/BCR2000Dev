from datetime import datetime, timedelta, timezone
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[2] / "tools"))
import driverkit_probe as probe
import driverkit_xcode_project as project


def configuration():
    # Synthetic descriptor, not a captured device configuration or preset.
    raw = bytearray([9, 2, 32, 0, 1, 1, 0, 128, 1])
    raw.extend([9, 4, 1, 0, 2, 1, 3, 0, 0])
    raw.extend([7, 5, 0x81, 2, 64, 0, 0])
    raw.extend([7, 5, 0x02, 2, 4, 0, 0])
    return bytes(raw)


class DriverKitProbeTests(unittest.TestCase):
    def test_apple_silicon_uses_provisioning_udid_not_hardware_uuid(self):
        self.assertEqual(
            probe.provisioning_udid({"provisioning_UDID": "registered", "platform_UUID": "other"}), "registered"
        )
        self.assertEqual(probe.provisioning_udid({"platform_UUID": "intel"}), "intel")
        with self.assertRaises(ValueError):
            probe.provisioning_udid({})

    def test_patch_changes_only_one_endpoint_size_byte(self):
        raw = configuration()
        patched, offset = probe.patch_configuration(raw)
        self.assertEqual(offset, 29)
        self.assertEqual([(a, b) for a, b in zip(raw, patched) if a != b], [(4, 8)])
        self.assertEqual(raw[22], 64)

    def test_patch_rejects_truncated_wrong_type_and_already_patched(self):
        raw = configuration()
        for invalid in (raw[:-1], b"", raw + b"\0", raw[:9] + bytes([0]) + raw[10:]):
            with self.assertRaises(ValueError):
                probe.patch_configuration(invalid)
        patched, _ = probe.patch_configuration(raw)
        with self.assertRaises(ValueError):
            probe.patch_configuration(patched)
        invalid = bytearray(raw)
        invalid[28] = 3  # Interrupt cannot stand in for the Bulk OUT under investigation.
        with self.assertRaises(ValueError):
            probe.patch_configuration(bytes(invalid))

    def test_report_rejects_wrong_device_multiple_devices_and_unknown_speed(self):
        target = {
            "vendor": 0x1397,
            "product": 0xBC,
            "USBSpeed": 1,
            "bcdDevice": 0x100,
            "cachedConfiguration": {
                "status": "ok",
                "currentConfiguration": 1,
                "configurationHex": configuration().hex(),
            },
        }
        self.assertEqual(probe.configuration_from_report({"targets": [target]}), configuration())
        for report in (
            {"targets": []},
            {"targets": [target, target]},
            {"targets": [dict(target, vendor=123)]},
            {"targets": [dict(target, USBSpeed=True)]},
        ):
            with self.assertRaises(ValueError):
                probe.configuration_from_report(report)

    def test_control_only_adds_marker_and_both_variants_match_exact_hardware(self):
        patched, _ = probe.patch_configuration(configuration())
        control = probe.info_plist("control", patched)
        candidate = probe.info_plist("override", patched)
        for info in (control, candidate):
            personality = info["IOKitPersonalities"][probe.CLASS]
            self.assertEqual(
                (personality["idVendor"], personality["idProduct"], personality["bcdDevice"]), (0x1397, 0xBC, 0x100)
            )
            self.assertEqual(personality["IOProviderClass"], "IOUSBHostDevice")
            self.assertNotIn("InhibitAudioClassDriver", personality["IOProviderMergeProperties"])
        props = control["IOKitPersonalities"][probe.CLASS]["IOProviderMergeProperties"]
        self.assertEqual(set(props), {"BCRDescriptorProbeVersion"})
        override = candidate["IOKitPersonalities"][probe.CLASS]["IOProviderMergeProperties"]["kUSBDescriptorOverride"]
        self.assertEqual(override["descriptor"], patched)

    def profile(self, grant=None):
        return {
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1),
            "Entitlements": {
                "application-identifier": "TEAMID1234." + probe.DRIVER_ID,
                "com.apple.developer.driverkit": True,
                probe.USB_ENTITLEMENT: grant or [{"idVendor": 0x1397, "idProduct": 0xBC}],
            },
        }

    def test_profile_requires_unexpired_driver_usb_and_matching_app_id(self):
        now = datetime.now(timezone.utc)
        profile = self.profile()
        self.assertTrue(probe.profile_candidate(profile, now))
        self.assertFalse(probe.profile_candidate(dict(profile, ExpirationDate=now - timedelta(seconds=1)), now))
        for change in (
            {"com.apple.developer.driverkit": False},
            {probe.USB_ENTITLEMENT: True},
            {"application-identifier": "TEAMID1234.other.driver"},
            {probe.USB_ENTITLEMENT: [{"idVendor": 0x1234}]},
        ):
            value = dict(profile, Entitlements=dict(profile["Entitlements"], **change))
            self.assertFalse(probe.profile_candidate(value, now))

    def test_wildcard_usb_grant_is_development_only(self):
        profile = self.profile([{"idVendor": "*"}])
        now = datetime.now(timezone.utc)
        self.assertFalse(probe.profile_candidate(profile, now))
        profile["Entitlements"]["get-task-allow"] = True
        self.assertTrue(probe.profile_candidate(profile, now))

    def test_empty_iig_outputs_are_not_a_success(self):
        with tempfile.TemporaryDirectory() as directory:
            header, implementation = Path(directory) / "p.h", Path(directory) / "p.cpp"
            header.write_text("")
            implementation.write_text("")
            self.assertFalse(probe.generated_sources_valid(header, implementation))
            header.write_text(probe.CLASS)
            implementation.write_text(probe.CLASS)
            self.assertTrue(probe.generated_sources_valid(header, implementation))

    def test_project_embeds_minimal_driver_and_separates_development_grant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            artifacts = root / "build/probe"
            driver = artifacts / "control" / (probe.DRIVER_ID + ".dext")
            driver.mkdir(parents=True)
            (driver / "Info.plist").write_bytes(plistlib.dumps(probe.info_plist("control", b"")))
            (root / "experiments/DriverKitProbe").mkdir(parents=True)
            for name in ("BCRDescriptorProbe.iig", "ProbeHost.swift"):
                (root / "experiments/DriverKitProbe" / name).write_text("test source\n")
            with patch.object(project, "ROOT", root):
                path = project.generate(artifacts, "TEAMID1234", "control")
            pbx = plistlib.loads((path / "project.pbxproj").read_bytes())
            copy_phases = [v for v in pbx["objects"].values() if v["isa"] == "PBXCopyFilesBuildPhase"]
            self.assertEqual(copy_phases[0]["dstPath"], "$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions")
            grants = plistlib.loads((path.parent / "Driver-Development.entitlements").read_bytes())
            self.assertEqual(grants[probe.USB_ENTITLEMENT], [{"idVendor": "*"}])
            self.assertFalse((path.parent / "embedded.provisionprofile").exists())


if __name__ == "__main__":
    unittest.main()
