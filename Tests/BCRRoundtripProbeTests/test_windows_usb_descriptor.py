from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[2] / "tools"))
import windows_usb_descriptor as probe


class USBDescriptorTests(unittest.TestCase):
    def config(self, rest):
        return bytes([9, 2]) + struct.pack("<H", 9 + len(rest)) + bytes([1, 1, 0, 0x80, 50]) + rest

    def test_parses_midi_interface_and_four_byte_bulk_out(self):
        interface = bytes([9, 4, 1, 0, 1, 1, 3, 0, 0])
        endpoint = bytes([7, 5, 2, 2, 4, 0, 0])
        association = bytes([5, 0x25, 1, 1, 1])
        result = probe.parse(self.config(interface + endpoint + association))
        self.assertEqual(result[0]["subclass"], 3)
        self.assertEqual(result[1], {"endpointAddress": "0x2", "attributes": 2, "maxPacket": 4, "interval": 0})
        self.assertEqual(result[2]["classEndpoint"], list(association))

    def test_truncated_or_zero_length_descriptors_are_rejected(self):
        for body in [b"\x00\x04", b"\x09\x04", bytes([8, 4, 1, 0, 1, 1, 3, 0]), bytes([6, 5, 2, 2, 4, 0])]:
            with self.assertRaises(ValueError):
                probe.parse(self.config(body))
        with self.assertRaises(ValueError):
            probe.parse(self.config(b"")[:-1])

    def test_full_speed_bulk_warning_does_not_confuse_midi_event_length(self):
        descriptors = [
            {"endpointAddress": "0x2", "attributes": 2, "maxPacket": 4},
            {"endpointAddress": "0x81", "attributes": 2, "maxPacket": 64},
            {"endpointAddress": "0x83", "attributes": 3, "maxPacket": 4},
        ]
        warnings = probe.full_speed_bulk_warnings(descriptors, 1)
        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0]["endpoint"], "0x2")
        self.assertEqual(probe.full_speed_bulk_warnings(descriptors, 2), [])

    def test_setupapi_structures_have_expected_pointer_alignment(self):
        self.assertEqual(probe.C.sizeof(probe.GUID), 16)
        self.assertEqual(probe.C.sizeof(probe.IFACE), 32 if probe.C.sizeof(probe.PTR) == 8 else 28)


if __name__ == "__main__":
    unittest.main()
