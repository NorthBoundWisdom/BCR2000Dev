import importlib.util
import io
import os
from pathlib import Path
import plistlib
import sys
import tempfile
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
    def test_offscreen_bundle_is_an_accessory_before_the_process_starts(self):
        # AppKit reads LSUIElement before didFinishLaunching; a delegate-only
        # activation-policy change races the desktop auditor on hosted runners.
        for flags, expected, ci in (
            ([], True, ""),
            ([], True, "true"),
            ([], True, "false"),
            (["--foreground"], False, "true"),
        ):
            with self.subTest(flags=flags, ci=ci), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                bundle = root / "Source.app"
                macos = bundle / "Contents/MacOS"
                macos.mkdir(parents=True)
                (macos / "App").touch()
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "App"}))

                def launch(command, **kwargs):
                    info = plistlib.loads((Path(command[0]).parents[1] / "Info.plist").read_bytes())
                    self.assertEqual(info.get("LSUIElement", False), expected)
                    raise RuntimeError("launch inspected")

                previous = Path.cwd()
                try:
                    os.chdir(root)
                    with (
                        patch.dict(os.environ, {"GITHUB_ACTIONS": ci}),
                        patch.object(integration.subprocess, "run"),
                        patch.object(integration, "DesktopAudit") as audit,
                        patch.object(integration.subprocess, "Popen", side_effect=launch),
                        self.assertRaisesRegex(RuntimeError, "launch inspected"),
                    ):
                        integration.main(["--bundle", str(bundle), *flags])
                    if expected:
                        self.assertEqual(audit.call_args.kwargs, {"prepare_ci_desktop": ci == "true"})
                    else:
                        audit.assert_not_called()
                finally:
                    os.chdir(previous)

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
        app = Mock(poll=Mock(return_value=None))
        integration.stop_app(app, True)
        app.kill.assert_called_once_with()
        app.terminate.assert_not_called()
        app.wait.assert_called_once_with(timeout=5)

    def test_foreground_shutdown_keeps_graceful_termination(self):
        app = Mock(poll=Mock(return_value=None))
        integration.stop_app(app, False)
        app.terminate.assert_called_once_with()
        app.kill.assert_not_called()

    def test_startup_failure_preserves_signal_source_phase_and_app_log_before_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "lifecycle-phase.txt").write_text("launch")
            (root / "desktop-audit-signals.jsonl").write_text(
                '{"source":"desktop_audit","signal":"SIGKILL","reason":"target became frontmost"}\n'
            )
            (root / "app.log").write_text("bcr.integration_startup: app.init\n")
            app = Mock(pid=123, poll=Mock(return_value=-9))
            error = integration.startup_failure(app, root, "isolated app exited before listening")
            report = str(error)
            for evidence in (
                "pid=123",
                "SIGKILL",
                "phase=launch",
                "desktop_audit",
                "target became frontmost",
                "app.init",
            ):
                self.assertIn(evidence, report)
            integration.stop_app(app, True)
            app.kill.assert_not_called()
            self.assertEqual((root / "launch-failure.txt").read_text(), report)

    def test_startup_failure_reports_empty_log_and_unknown_signal_sender(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "lifecycle-phase.txt").write_text("launch")
            app = Mock(pid=123, poll=Mock(return_value=-9))
            report = str(integration.startup_failure(app, root, "isolated app exited before listening"))
            self.assertIn("signal sender unknown", report)
            self.assertIn("no app startup marker reached", report)

    def test_invalid_port_fails_before_any_process_or_directory_setup(self):
        with patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit):
            integration.parse_arguments(["--port", "80"])


if __name__ == "__main__":
    unittest.main()
