from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[2] / "tools"))
from bcr_roundtrip import run_roundtrip
from midi_feedback_probe import CC, InputEvents, Port


class FakeDevice:
    def __init__(self, identity=True, target=True, dropped=0):
        self.identity, self.target = identity, target
        self.events = InputEvents()
        self.events.dropped = dropped
        self.value = 13
        self.sent = []
        self.closed = False

    def ports(self, input):
        return [Port(0, "BCR2000 Virtual")]

    def open(self, source, destination):
        pass

    def collect(self, seconds):
        return []

    def query(self, command, seconds):
        if command == 1:
            frame = bytes.fromhex("F0 00 20 32 00 15 02") + b"BCR2000 1.10\xf7"
            return [], [frame] if self.identity else []
        return ([CC(1, 74, self.value)] if self.target else []) + [CC(1, 75, 20), CC(1, 76, 0)], []

    def send(self, message):
        self.sent.append(message)
        self.value = message.value

    def close(self):
        self.closed = True


class RoundtripGuardTests(unittest.TestCase):
    def args(self, **changes):
        values = dict(
            input=None,
            output=None,
            test_cc=74,
            channel=1,
            wait=0.2,
            hold_max=False,
            expected_identity=None,
            report=None,
        )
        values.update(changes)
        return SimpleNamespace(**values)

    def execute(self, device, args):
        with patch("bcr_roundtrip.time.sleep"), patch("builtins.print"):
            return run_roundtrip(args, lambda: device)

    def test_all_five_values_and_restoration_are_verified(self):
        device = FakeDevice()
        report = self.execute(device, self.args())
        self.assertTrue(report["valueRoundtripPassed"])
        self.assertEqual([m.value for m in device.sent], [0, 32, 64, 96, 127, 13])
        self.assertEqual(report["finalObserved"], 13)
        self.assertEqual(report["cleanup"], "closed")

    def test_missing_identity_target_or_overflow_never_writes(self):
        for device in [FakeDevice(identity=False), FakeDevice(target=False), FakeDevice(dropped=1)]:
            with self.assertRaises(RuntimeError):
                self.execute(device, self.args())
            self.assertEqual(device.sent, [])
            self.assertTrue(device.closed)

    def test_identity_mismatch_and_unwritable_report_never_write(self):
        device = FakeDevice()
        with self.assertRaises(RuntimeError):
            self.execute(device, self.args(expected_identity="BCR2000 other"))
        self.assertEqual(device.sent, [])
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(OSError):
                self.execute(device, self.args(report=str(Path(directory) / "missing/report.json")))
        self.assertEqual(device.sent, [])

    def test_readonly_default_and_explicit_hold_are_distinct(self):
        device = FakeDevice()
        self.execute(device, self.args(test_cc=None))
        self.assertEqual(device.sent, [])
        report = self.execute(device, self.args(hold_max=True))
        self.assertEqual(report["finalObserved"], 127)

    def test_failure_writes_report_and_closes(self):
        import json

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            device = FakeDevice(identity=False)
            with self.assertRaises(RuntimeError):
                self.execute(device, self.args(report=str(path)))
            report = json.loads(path.read_text())
            self.assertIn("error", report)
            self.assertEqual(report["cleanup"], "closed")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
