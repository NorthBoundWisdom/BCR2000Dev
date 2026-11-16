from pathlib import Path
import unittest

from configs import check_owned_virtual_boundary as boundary


class OwnedVirtualBoundaryTests(unittest.TestCase):
    def test_actual_production_files_and_factory_are_closed(self):
        self.assertEqual(boundary.check(), [])

    def test_deliberate_enumeration_lookup_and_native_factory_fail_the_production_source_gate(self):
        for statement in [
            "MIDIGetNumberOfSources()",
            "MIDIGetSource(0)",
            "MIDIGetNumberOfDestinations()",
            "MIDIGetDestination(0)",
            "MIDIObjectFindByUniqueID(id, &ref, &type)",
            "CoreMIDIService()",
            "let enumerate = MIDIGetNumberOfSources",
            "let factory = CoreMIDIService.init",
        ]:
            with self.subTest(statement=statement):
                self.assertTrue(boundary.inspect(statement))
        self.assertEqual(boundary.inspect('// MIDIGetSource(0)\nlet note = "MIDIGetSource(0)"'), [])

    def test_owned_factory_selection_cannot_be_fooled_by_a_native_call_in_its_body(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "Sources/BCRProviderService/ProviderService.swift").read_text()
        body = boundary.factory_branch(source)
        self.assertFalse(boundary.inspect(body))
        self.assertTrue(boundary.inspect(body[:-1] + " CoreMIDIService(); }"))
