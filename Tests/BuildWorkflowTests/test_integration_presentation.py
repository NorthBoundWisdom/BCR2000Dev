import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

from tools import mcp_smoke, native_ui

spec = importlib.util.spec_from_file_location(
    "integration_presentation_under_test", Path(__file__).resolve().parents[2] / "tools/mcp_integration.py"
)
integration = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {"mcp_smoke": mcp_smoke, "native_ui": native_ui}):
    spec.loader.exec_module(integration)


class IntegrationPresentationTests(unittest.TestCase):
    def test_protocol_only_defaults_offscreen_and_script_defaults_foreground(self):
        self.assertTrue(integration.uses_offscreen(integration.parse_arguments([])))
        self.assertFalse(integration.uses_offscreen(integration.parse_arguments(["--script", "case.py"])))

    def test_explicit_overrides_apply_with_or_without_scripts(self):
        for script in ([], ["--script", "case.py"]):
            with self.subTest(script=script):
                self.assertTrue(integration.uses_offscreen(integration.parse_arguments([*script, "--offscreen"])))
                self.assertFalse(integration.uses_offscreen(integration.parse_arguments([*script, "--foreground"])))

    def test_switches_are_mutually_exclusive_before_launch(self):
        with patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit) as error:
            integration.parse_arguments(["--offscreen", "--foreground"])
        self.assertEqual(error.exception.code, 2)

    def test_child_arguments_forward_presentation_fixture_and_language(self):
        args = integration.parse_arguments(
            ["--offscreen", "--connection-fixture", "--language", "en", "--script", "case.py"]
        )
        command = integration.app_arguments(Path("test.app/Contents/MacOS/Test"), args)
        self.assertIn("--offscreen", command)
        self.assertIn("--integration-test", command)
        self.assertIn("--connection-fixture", command)
        self.assertEqual(command[-2:], ["-AppleLanguages", "(en)"])
        args = integration.parse_arguments(["--foreground"])
        self.assertNotIn("--offscreen", integration.app_arguments(Path("app"), args))

    def test_offscreen_shutdown_never_requests_interactive_termination(self):
        app = Mock()
        integration.stop_app(app, True)
        app.kill.assert_called_once_with()
        app.terminate.assert_not_called()
        app.wait.assert_called_once_with(timeout=5)

    def test_foreground_shutdown_keeps_graceful_termination(self):
        app = Mock()
        integration.stop_app(app, False)
        app.terminate.assert_called_once_with()
        app.kill.assert_not_called()

    def test_invalid_port_fails_before_any_process_or_directory_setup(self):
        with patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit):
            integration.parse_arguments(["--port", "80"])


if __name__ == "__main__":
    unittest.main()
