import ctypes
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("midi_feedback_probe", Path(__file__).parents[2] / "tools/midi_feedback_probe.py")
probe = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = probe
spec.loader.exec_module(probe)


class FakeBackend:
    def __init__(self, failure=None):
        self.events = probe.InputEvents()
        self.sent = []
        self.failure = failure

    def send(self, message):
        self.sent.append(message)
        if self.failure == len(self.sent):
            raise RuntimeError("send failed")


class FeedbackProbeTests(unittest.TestCase):
    def test_pack_cc_matches_native_windows_byte_order(self):
        self.assertEqual(probe.CC(1, 8, 127).packed(), 0x7F08B0)
        for channel in range(1, 17):
            for value in (0, 32, 64, 96, 127):
                cc = probe.CC(channel, 8, value)
                self.assertEqual(probe.CC.unpack(cc.packed()), cc)
        self.assertIsNone(probe.CC.unpack(0x7F0890))
        for cc in [probe.CC(0, 8, 0), probe.CC(17, 8, 0), probe.CC(1, 128, 0), probe.CC(1, 8, 128)]:
            with self.assertRaises(ValueError):
                cc.packed()

    def test_ump1_and_midi2_downconversion_targets_are_exact_at_boundaries(self):
        self.assertEqual(probe.ump_cc(probe.CC(1, 8, 127), 1), [0x20B0087F])
        self.assertEqual(probe.ump_cc(probe.CC(1, 8, 127), 2), [0x40B00800, 0xFFFFFFFF])
        self.assertEqual(probe.ump_cc(probe.CC(16, 8, 0), 2), [0x40BF0800, 0])
        for value in range(128):
            self.assertEqual(probe.ump_cc(probe.CC(1, 8, value), 2)[1] >> 25, value)
        with self.assertRaises(ValueError):
            probe.ump_cc(probe.CC(1, 8, 0), 3)

    def test_winmm_caps_have_fixed_windows_layout_on_all_hosts(self):
        self.assertEqual(ctypes.sizeof(probe.InputCaps), 76)
        self.assertEqual(ctypes.sizeof(probe.OutputCaps), 84)
        self.assertEqual(probe.OutputCaps.support.offset, 80)

    def test_port_resolution_rejects_ambiguous_and_preserves_explicit_choice(self):
        ports = [probe.Port(0, "Microsoft GS"), probe.Port(1, "BCR2000")]
        self.assertEqual(probe.resolve(ports, None, "output").id, 1)
        multi = [probe.Port(1, "BCR2000 Port 1"), probe.Port(2, "BCR2000 Port 2")]
        self.assertEqual(probe.resolve(multi, None, "output").id, 1)
        self.assertEqual(probe.resolve(multi, 2, "output").id, 2)
        with self.assertRaises(ValueError):
            probe.resolve(multi, 99, "output")
        with self.assertRaises(ValueError):
            probe.resolve([probe.Port(1, "BCR2000"), probe.Port(2, "BCR2000")], None, "output")

    def test_other_output_requires_explicit_interface_opt_in(self):
        port = probe.Port(4, "USB MIDI Interface")
        with self.assertRaises(ValueError):
            probe.validate_output(port)
        with self.assertRaises(ValueError):
            probe.validate_output(port, True)
        probe.validate_output(port, True, 2, 4)
        probe.validate_output(probe.Port(1, "BCR2000"))

    def test_sweep_sends_exact_five_values_and_restores_observed_value(self):
        backend = FakeBackend()
        with patch("builtins.print"):
            probe.sweep(backend, probe.CC(3, 12, 17), wait=lambda _: None)
        self.assertEqual([m.value for m in backend.sent], [0, 32, 64, 96, 127, 17])
        self.assertTrue(all(m.channel == 3 and m.controller == 12 for m in backend.sent))

    def test_failed_or_cancelled_sweep_attempts_restore(self):
        for failure in (1, 3):
            backend = FakeBackend(failure=failure)
            with patch("builtins.print"), self.assertRaises(RuntimeError):
                probe.sweep(backend, probe.CC(1, 8, 7), wait=lambda _: None)
            self.assertEqual(backend.sent[-1].value, 7)
        backend = FakeBackend()
        def cancel(_):
            raise KeyboardInterrupt()
        with patch("builtins.print"), self.assertRaises(KeyboardInterrupt):
            probe.sweep(backend, probe.CC(1, 8, 9), wait=cancel)
        self.assertEqual(backend.sent[-1].value, 9)

    def test_multiple_cc_or_nrpn_learning_never_sends(self):
        for messages in [ [probe.CC(1, 8, 1), probe.CC(1, 9, 1)], [probe.CC(1, 99, 1)] ]:
            backend = FakeBackend()
            for message in messages:
                backend.events.put(message.packed())
            with patch("builtins.print"), self.assertRaises(ValueError):
                probe.learn(backend, 1)
            self.assertEqual(backend.sent, [])

    def test_queue_overflow_is_reported_and_callback_errors_surface(self):
        backend = FakeBackend()
        backend.events.queue = probe.queue.Queue(maxsize=1)
        backend.events.put(1); backend.events.put(2)
        self.assertEqual(backend.events.dropped, 1)
        backend = FakeBackend()
        backend.events.put(RuntimeError("bad callback"))
        with self.assertRaisesRegex(RuntimeError, "bad callback"):
            probe.read_cc(backend)

    def test_macos_packet_alignment_and_non_cc_shapes(self):
        for aligned in (False, True):
            storage = ctypes.create_string_buffer(128)
            base = ctypes.addressof(storage)
            probe.U32.from_address(base).value = 2
            first = base + 4
            one = bytes([0xC0, 4, 0xB0, 8, 7, 0xF8])
            probe.U16.from_address(first+8).value = len(one)
            ctypes.memmove(first+10, one, len(one))
            second = first+10+len(one)
            if aligned:
                second = (second+3) & ~3
            two = bytes([0xF0, 1, 2, 0xF7, 0xB2, 9, 127])
            probe.U16.from_address(second+8).value = len(two)
            ctypes.memmove(second+10, two, len(two))
            self.assertEqual(probe.mac_cc_packets(base, 4, aligned), [probe.CC(1, 8, 7).packed(), probe.CC(3, 9, 127).packed()])


if __name__ == "__main__":
    unittest.main()
