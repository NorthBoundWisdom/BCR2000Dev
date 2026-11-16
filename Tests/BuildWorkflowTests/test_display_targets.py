import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("display_targets", ROOT / "configs/display_targets.py")
display = importlib.util.module_from_spec(spec)
spec.loader.exec_module(display)


class DisplayTargetTests(unittest.TestCase):
    def fixture(self):
        contract = {
            "discovery": {
                "source": "hardware",
                "expected": {"mapping_revision": "m"},
                "profile": {
                    "id": "test",
                    "version": "1.4",
                    "controls": [
                        {
                            "id": "pushEncoder.1.1",
                            "input_kind": "absolute",
                            "feedback_kinds": ["value"],
                            "feedback_range": {"minimum": 0, "maximum": 127, "step": 1},
                        },
                        {"id": "button.1.1", "input_kind": "button", "feedback_kinds": []},
                    ],
                },
            }
        }
        mapping = {
            "entries": [
                {"control": {"section": "pushEncoder", "row": 1, "index": 1}, "ringMode": "12dot"},
                {"control": {"section": "button", "row": 1, "index": 1}, "visualizationOnly": True},
            ]
        }
        return contract, mapping

    def testDefaultEligibilityDoesNotPromoteVisualizationOnlyButton(self):
        contract, mapping = self.fixture()
        actual = display.targets(contract, mapping)
        self.assertEqual([r["id"] for r in actual["targets"]], ["pushEncoder.1.1"])
        self.assertEqual(actual["no_feedback_controls"], ["button.1.1"])
        self.assertIn("not attended qualified", actual["targets"][0]["eligibility"])
        self.assertIn("actual preset not read", actual["targets"][0]["style_evidence"])

    def testDisplayDeclarationCannotOverrideVisualizationOnlyPolicy(self):
        contract, mapping = self.fixture()
        contract["discovery"]["profile"]["controls"][1]["feedback_kinds"] = ["indicator"]
        with self.assertRaisesRegex(ValueError, "Visualization-only"):
            display.targets(contract, mapping)

    def testUnknownStyleIsNotGuessedAndChangedMapUpdatesStyle(self):
        contract, mapping = self.fixture()
        del mapping["entries"][0]["ringMode"]
        self.assertEqual(display.targets(contract, mapping)["targets"][0]["style"], "unknown")
        mapping["entries"][0]["ringMode"] = "2dot"
        self.assertEqual(display.targets(contract, mapping)["targets"][0]["style"], "2dot")

    def testCheckDetectsChangedProfileMapAndEditedMarkdown(self):
        contract, mapping = self.fixture()
        simulation = copy.deepcopy(contract)
        simulation["discovery"]["source"] = "simulation"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, data in (
                ("control-contract.json", simulation),
                ("display-mock-map.json", mapping),
                ("hardware-control-contract.json", contract),
                ("hardware-map.json", mapping),
            ):
                (root / name).write_text(json.dumps(data))
            display.generate(root)
            display.generate(root, True)
            mapping["entries"][0]["ringMode"] = "1dot"
            (root / "hardware-map.json").write_text(json.dumps(mapping))
            with self.assertRaisesRegex(ValueError, "display-targets.json"):
                display.generate(root, True)
            display.generate(root)
            (root / "DISPLAY_TARGETS.md").write_text("manual edit")
            with self.assertRaisesRegex(ValueError, "DISPLAY_TARGETS.md"):
                display.generate(root, True)
