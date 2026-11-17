from pathlib import Path
import unittest

from configs.check_gui_virtual_boundary import check

ROOT = Path(__file__).resolve().parents[2]
PATHS = ("Sources/BCRAgentConsole/GUIVirtualLaunch.swift", "Sources/BCRAgentConsole/ConsoleDeviceWork.swift")


class GUIVirtualBoundaryTests(unittest.TestCase):
    def sources(self):
        return {name: (ROOT / name).read_text() for name in PATHS}

    def test_actual_permanent_driver_and_virtual_branch_are_closed(self):
        check(self.sources())

    def test_native_factory_or_enumeration_added_to_virtual_branch_is_rejected(self):
        for operation in (
            "CoreMIDIService(selection: savedSelection)",
            "MIDIGetNumberOfSources()",
            "KeychainMCPCredentialStore()",
            "OutputTransportRouter()",
        ):
            with self.subTest(operation=operation):
                sources = self.sources()
                name = PATHS[1]
                sources[name] = sources[name].replace(
                    "midi = context.midi", "_ = " + operation + "; midi = context.midi"
                )
                with self.assertRaisesRegex(ValueError, "Native IO reference"):
                    check(sources)

    def test_native_reference_in_permanent_driver_or_removed_source_gate_is_rejected(self):
        sources = self.sources()
        sources[PATHS[0]] = sources[PATHS[0]].replace(
            "final class PermanentMockOnlyMIDIService: MIDIService {",
            "final class PermanentMockOnlyMIDIService: MIDIService {\nlet bad = MIDIGetNumberOfSources()",
        )
        with self.assertRaisesRegex(ValueError, "Native IO reference"):
            check(sources)
        sources = self.sources()
        sources[PATHS[1]] = sources[PATHS[1]].replace(
            "permitsHardwareSource: !runtimeMode.isVirtual", "permitsHardwareSource: true"
        )
        with self.assertRaisesRegex(ValueError, "source restriction"):
            check(sources)
