import ctypes
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[2] / "tools"))
import windows_bcr_roundtrip as probe
from midi_feedback_probe import CC


class BCRRoundtripTests(unittest.TestCase):
    def test_only_readonly_commands_can_be_constructed(self):
        self.assertEqual(probe.request_bytes(1), bytes.fromhex("F0 00 20 32 7F 15 01 F7"))
        self.assertEqual(probe.request_bytes(0x43), bytes.fromhex("F0 00 20 32 7F 15 43 F7"))
        for value in range(128):
            if value not in (1, 0x43):
                with self.assertRaises(ValueError):
                    probe.request_bytes(value)

    def test_midi_header_uses_native_pointer_width_and_fixed_dwords(self):
        self.assertEqual(ctypes.sizeof(probe.MIDIHDR), 120 if ctypes.sizeof(ctypes.c_void_p) == 8 else 64)
        self.assertEqual(probe.MIDIHDR.buffer_length.offset, ctypes.sizeof(ctypes.c_void_p))

    def test_fragmented_identity_with_realtime_bytes(self):
        frames = probe.SysExFrames()
        frames.feed(bytes.fromhex("F0 00 20 32 F8 00"))
        frames.feed(bytes.fromhex("15 02") + b"BCR2000 1.10" + b"\xF7")
        self.assertIsNone(frames.partial)
        self.assertEqual(probe.identity_info(frames.frames[0]), {"deviceID": 0, "model": "BCR2000", "identity": "BCR2000 1.10"})
        self.assertIsNone(probe.identity_info(bytes.fromhex("F0 00 20 32 00 15 43 F7")))

    def test_malformed_or_unbounded_sysex_fails_visibly(self):
        for data in (b"\xF0\x01\xF0", b"\xF0\x90", b"\xF0" + bytes(8192)):
            with self.assertRaises(ValueError):
                probe.SysExFrames().feed(data)

    def test_snapshot_requires_more_than_a_single_echo(self):
        self.assertIsNone(probe.snapshot_values([CC(1, 8, 127)], 1, 8))
        self.assertEqual(probe.snapshot_values([CC(1, 8, 127), CC(1, 9, 20)], 1, 8), 127)
        self.assertIsNone(probe.snapshot_values([CC(1, 9, 20), CC(1, 10, 0)], 1, 8))
        with self.assertRaises(ValueError):
            probe.snapshot_values([CC(1, 8, 127), CC(1, 8, 0), CC(1, 9, 20)], 1, 8)


if __name__ == "__main__":
    unittest.main()
