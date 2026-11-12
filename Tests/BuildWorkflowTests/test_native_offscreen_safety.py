import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools import native_ui


class NativeOffscreenSafetyTests(unittest.TestCase):
    def ui(self, offscreen):
        result = native_ui.NativeUI.__new__(native_ui.NativeUI)
        result.pid = 123
        result.offscreen = offscreen
        return result

    def test_offscreen_keyboard_events_are_rejected_before_apple_events(self):
        with patch.object(native_ui.subprocess, "run") as command:
            for text in ("key code 36", "KEY CODE 53", 'keystroke "x"', "key down command"):
                with self.subTest(text=text), self.assertRaisesRegex(RuntimeError, "keyboard events are forbidden"):
                    self.ui(True).run(text)
            command.assert_not_called()

    def test_offscreen_filters_focus_and_position_but_keeps_value_edits(self):
        response = subprocess.CompletedProcess([], 0, "ok", "")
        body = (
            "set frontmost to true\nset position of mainWindow to {80,80}\n"
            "set focused of text field 1 of mainWindow to true\n"
            'set size of mainWindow to {1200,760}\nset value of text field 1 of mainWindow to "value"'
        )
        with patch.object(native_ui.subprocess, "run", return_value=response) as command:
            self.assertEqual(self.ui(True).run(body), "ok")
        source = command.call_args.args[0][-1]
        self.assertNotIn("set frontmost", source)
        self.assertNotIn("set position", source)
        self.assertNotIn("set focused", source)
        self.assertIn("set size", source)
        self.assertIn('set value of text field 1 of mainWindow to "value"', source)

    def test_foreground_operations_are_preserved_without_executing_them(self):
        response = subprocess.CompletedProcess([], 0, "", "")
        body = "set frontmost to true\nkey code 36"
        with patch.object(native_ui.subprocess, "run", return_value=response) as command:
            self.ui(False).run(body)
        self.assertIn(body, command.call_args.args[0][-1])

    def test_offscreen_capture_uses_own_app_rendering_not_screencapture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            nonce = "57afbf29-168a-41fd-960c-0af8cba77acc"

            def render(action, value):
                self.assertEqual((action, value), ("snapshot", nonce))
                (root / f"capture-{nonce}.png").write_bytes(b"own App view")

            ui = self.ui(True)
            with (
                patch.dict(os.environ, {"BCR_INTEGRATION_DIRECTORY": temporary}),
                patch.object(native_ui.uuid, "uuid4", return_value=nonce),
                patch.object(ui, "command", side_effect=render),
                patch.object(native_ui.subprocess, "run") as command,
            ):
                ui.capture(root / "result.png")
            command.assert_not_called()
            self.assertEqual((root / "result.png").read_bytes(), b"own App view")


if __name__ == "__main__":
    unittest.main()
