import contextlib
import io
import sys
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from midi_feedback_probe import CC, Port
from read_bcr_preset import capture
from verify_encoder_surface import verify


class CaptureBackend:
    def __init__(self):
        self.events = SimpleNamespace(dropped=0)
        self.frames = SimpleNamespace(frames=[], partial=None)
        self.requests = []
        self.collections = 0
        self.closed = False

    def ports(self, input):
        return [Port(0, "BCR2000 Port 1")]

    def open(self, *ports):
        pass

    def close(self):
        self.closed = True

    def query(self, command, seconds):
        if command == 1:
            return [], [bytes([0xF0, 0, 0x20, 0x32, 0, 0x15, 2]) + b"BCR2000 1.10\xf7"]
        return [CC(7, 44, 37)], []

    def _send_bytes(self, data):
        self.requests.append(data)

    def collect(self, seconds):
        if self.requests:
            self.collections += 1
            if self.collections == 20:  # Must not mistake a slow dump for completion.
                self.frames.frames.append(bytes([0xF0, 0, 0x20, 0x32, 0, 0x15, 0x20, 0, 0]) + b"$end\xf7")
        return []


class FakeApp:
    def __init__(self):
        self.values = {f"p{i}": 10.0 for i in range(56)}
        self.writes = []

    def call(self, name, args=None):
        if name == "get_status":
            return {
                "source": "hardware",
                "hardwareConnection": {"connected": True},
                "motionSafety": {"status": "disconnected"},
                "droppedFeedbackCount": 0,
            }
        if name == "list_controls":
            return [
                {
                    "control": {"section": "pushEncoder" if i < 32 else "encoder"},
                    "binding": {"kind": "controlChange", "channel": 6, "number": i},
                    "assignment": {
                        "encoderMode": "absolute",
                        "inverted": False,
                        "target": {"parameter": {"_0": f"p{i}"}},
                    },
                }
                for i in range(56)
            ]
        if name == "list_parameters":
            return [
                {"id": id, "value": value, "writable": True, "kind": "continuous", "minimum": 0, "maximum": 127}
                for id, value in self.values.items()
            ]
        if name == "set_parameters":
            self.writes.append(args)
            self.values.update({p["id"]: p["value"] for p in args["values"]})
            return []
        raise AssertionError(name)


class VerificationBackend(CaptureBackend):
    def __init__(self, app, mismatch=False):
        super().__init__()
        self.app = app
        self.mismatch = mismatch
        self.snapshots = 0

    def query(self, command, seconds):
        if command == 1:
            return super().query(command, seconds)
        self.snapshots += 1
        return [
            CC(7, i, round(value) if not (self.mismatch and self.snapshots == 1 and i == 55) else 128)
            for i, value in enumerate(self.app.values.values())
        ], []


class EncoderLearningToolsTests(unittest.TestCase):
    def testCaptureWaitsForEndAndUsesOnlyReadOnlyTemporaryPresetRequest(self):
        backend = CaptureBackend()
        with (
            tempfile.TemporaryDirectory() as root,
            patch("read_bcr_preset.MacBCR", return_value=backend),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            output = Path(root) / "new"
            capture(output)
            self.assertEqual(backend.requests, [bytes([0xF0, 0, 0x20, 0x32, 0, 0x15, 0x40, 0x7F, 0xF7])])
            self.assertTrue((output / "snapshot.json").exists())
            self.assertEqual((output / "current-preset.syx").stat().st_mode & 0o777, 0o600)
        self.assertTrue(backend.closed)

    def testReadbackPatternsAndRestorationUseAppWrites(self):
        app = FakeApp()
        backend = VerificationBackend(app)
        with (
            tempfile.TemporaryDirectory() as root,
            patch("verify_encoder_surface.time.sleep"),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            verify(app, backend, Path(root) / "report.json")
        self.assertEqual(len(app.writes), 6)
        self.assertEqual(set(app.values.values()), {10.0})
        self.assertTrue(backend.closed)

    def testReadbackMismatchFailsAndStillRestoresEveryParameter(self):
        app = FakeApp()
        backend = VerificationBackend(app, mismatch=True)
        with (
            tempfile.TemporaryDirectory() as root,
            patch("verify_encoder_surface.time.sleep"),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            with self.assertRaisesRegex(ValueError, "mismatch"):
                verify(app, backend, Path(root) / "report.json")
        self.assertEqual(set(app.values.values()), {10.0})
        self.assertTrue(backend.closed)
