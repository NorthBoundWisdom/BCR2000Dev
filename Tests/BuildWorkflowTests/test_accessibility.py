import tempfile
import unittest
from pathlib import Path

from configs.check_accessibility import check, controls, mask


class AccessibilityIdentifierTests(unittest.TestCase):
    def test_lexer_masks_nested_comments_raw_strings_and_interpolation(self):
        source = '''/* outer /* Button("fake") */ Toggle("fake") */
let text = #"Button(\"fake\") \\#(value("nested"))"#
let multiline = """Picker("fake")"""
// TextField("fake")
Button("real") { run() }.disabled(false).accessibilityIdentifier("real")
'''
        code = mask(source)
        self.assertEqual(len(code), len(source))
        self.assertEqual(code.count("\n"), source.count("\n"))
        rows = controls(source)
        self.assertEqual([row["kind"] for row in rows], ["Button"])
        self.assertIn("accessibilityIdentifier", rows[0]["modifiers"])

    def test_nested_label_controls_require_their_own_identifier(self):
        rows = controls("""Menu { Button("child") {} } label: { Text("menu") }
.accessibilityIdentifier("menu")
Toggle("next", isOn: $next).accessibilityIdentifier("next")""")
        self.assertEqual([r["kind"] for r in rows], ["Menu", "Button", "Toggle"])
        self.assertIn("accessibilityIdentifier", rows[0]["modifiers"])
        self.assertNotIn("accessibilityIdentifier", rows[1]["modifiers"])
        self.assertIn("accessibilityIdentifier", rows[2]["modifiers"])

    def test_missing_duplicate_and_each_physical_family_are_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Sources/BCRAgentConsole"
            source.mkdir(parents=True)
            panel = source / "SurfacePanelView.swift"
            panel.write_text("""private struct KnobCell: View {
.accessibilityIdentifier(presentation.control.accessibilityID)
}
""")
            (source / "Probe.swift").write_text("""Button("one") {}.accessibilityIdentifier("same")
Button("two") {}.accessibilityIdentifier("same")
Toggle("missing", isOn: $value)
// .accessibilityIdentifier("same")
let text = ".accessibilityIdentifier(\\\"same\\\")"
""")
            result = check(root)
            self.assertEqual(result["duplicates"], ["same"])
            self.assertEqual(len(result["missing"]), 4)
            self.assertTrue(any("Toggle" in item for item in result["missing"]))
            self.assertNotIn("Panel binding KnobCell", result["missing"])
            self.assertIn("Panel binding UserKeyCell", result["missing"])

    def test_repository_has_covered_controls_and_unique_templates(self):
        result = check()
        self.assertGreater(result["controls"], 200)
        self.assertEqual(result["missing"], [])
        self.assertEqual(result["duplicates"], [])
