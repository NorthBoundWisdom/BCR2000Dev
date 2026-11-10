import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[2] / "tools"))
from diagnostic_io import command_stage, write_json
from macos_bcr_roundtrip import request_words
from macos_test_session import classify_probe, compare_usb, load_target_profile, verify_manifest
from package_macos_diagnostics import sanitize_baseline, verify_architectures


class SessionInfrastructureTests(unittest.TestCase):
    def test_readonly_sysex7_words_are_complete_and_restricted(self):
        self.assertEqual(request_words(1), [0x30060020, 0x327F1501])
        self.assertEqual(request_words(0x43), [0x30060020, 0x327F1543])
        with self.assertRaises(ValueError):
            request_words(0x20)

    def test_hardware_success_cannot_be_inferred_from_exit_or_identity_alone(self):
        self.assertEqual(classify_probe(None), "invalid_report")
        self.assertEqual(classify_probe({}), "no_identity_response")
        data = {"identity": {"identity": "BCR2000 1.10"}, "snapshotCCCount": 56}
        self.assertEqual(classify_probe(data), "readback_verified")
        self.assertEqual(classify_probe(data, True), "value_roundtrip_failed")
        self.assertEqual(
            classify_probe(dict(data, valueRoundtripPassed=True, finalRequested=13, finalObserved=13), True),
            "value_roundtrip_verified",
        )
        self.assertEqual(classify_probe(dict(data, inputDropped=1)), "error")
        self.assertEqual(classify_probe(dict(data, cleanupError="still open")), "error")

    def test_descriptor_comparison_detects_missing_truncated_and_different(self):
        raw = bytes([9, 2, 9, 0, 0, 1, 0, 128, 50])
        native = {"targets": [{"USBSpeed": 1, "cachedConfiguration": {"status": "ok", "configurationHex": raw.hex()}}]}
        reference = {"targets": [{"configurationBytes": 9, "descriptors": []}]}
        self.assertEqual(compare_usb(native, reference)["status"], "matched")
        reference["targets"][0]["configurationBytes"] = 10
        self.assertEqual(compare_usb(native, reference)["status"], "different")
        self.assertEqual(compare_usb({}, reference)["status"], "unavailable")
        native["targets"][0]["cachedConfiguration"]["configurationHex"] = "00"
        self.assertEqual(compare_usb(native, reference)["status"], "error")

    def test_profile_is_explicit_strict_and_cannot_include_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "target.json"
            valid = {"version": 1, "channel": 1, "controller": 74, "expectedIdentity": "BCR2000 1.10"}
            path.write_text(json.dumps(valid))
            self.assertEqual(load_target_profile(path), valid)
            for bad in [
                dict(valid, password="secret"),
                dict(valid, version=True),
                dict(valid, controller=99),
                dict(valid, channel=False),
            ]:
                path.write_text(json.dumps(bad))
                with self.assertRaises(ValueError):
                    load_target_profile(path)

    def test_manifest_detects_tampering_and_escape_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "tool.py"
            source.write_text("print(1)\n")
            manifest = {"files": {"tool.py": hashlib.sha256(source.read_bytes()).hexdigest()}, "revision": "test"}
            (root / "manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(verify_manifest(root)["status"], "verified")
            source.write_text("changed")
            with self.assertRaises(ValueError):
                verify_manifest(root)
            manifest["files"] = {"../escape": "x"}
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                verify_manifest(root)

    def test_private_atomic_reports_do_not_follow_preexisting_temp(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            write_json(path, {"result": 1})
            write_json(path, {"result": 2})
            self.assertEqual(json.loads(path.read_text()), {"result": 2})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            temporary = path.with_name("report.json.tmp")
            temporary.write_text("keep")
            with self.assertRaises(FileExistsError):
                write_json(path, {"result": 3})
            self.assertEqual(temporary.read_text(), "keep")

    def test_subprocess_timeout_and_stderr_are_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            failure = command_stage(
                "failure",
                [sys.executable, "-c", 'import sys; print("reason", file=sys.stderr); sys.exit(7)'],
                directory,
            )
            self.assertEqual(failure["exitCode"], 7)
            self.assertIn("reason", (Path(directory) / failure["stderr"]).read_text())
            timeout = command_stage(
                "timeout", [sys.executable, "-c", "import time;time.sleep(5)"], directory, timeout=0.05
            )
            self.assertEqual(timeout["status"], "timeout")
            self.assertIsNone(timeout["exitCode"])

    def test_native_architecture_listing_requires_both_and_only_supported_slices(self):
        verify_architectures("x86_64 arm64\n")
        verify_architectures("arm64 x86_64")
        for value in ["arm64", "x86_64", "arm64 x86_64 extra", "arm64 arm64", ""]:
            with self.assertRaises(RuntimeError):
                verify_architectures(value)

    def test_packaging_reference_filters_unrelated_metadata(self):
        value = {
            "targets": [{"vendor": "0x1397", "product": "0xbc", "descriptors": [], "serial": "private"}],
            "password": "private",
        }
        self.assertEqual(
            sanitize_baseline(value), {"targets": [{"vendor": "0x1397", "product": "0xbc", "descriptors": []}]}
        )
        with self.assertRaises(ValueError):
            sanitize_baseline({"targets": []})


if __name__ == "__main__":
    unittest.main()
