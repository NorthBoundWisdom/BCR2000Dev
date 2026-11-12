from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from configs import macos_workflow


class OffscreenSmokeTests(unittest.TestCase):
    def _commands(self, environ, foreground=None):
        commands = []

        def launch(command, **kwargs):
            commands.append(command)
            language = command[-1].strip("()")
            Path(command[command.index("--stdout") + 1]).write_text(
                json.dumps(
                    {
                        "type": "bcr.native_startup",
                        "clientVersion": "0.1.0",
                        "language": language,
                        "settings": "Settings" if language == "en" else "设置",
                    },
                    separators=(",", ":"),
                )
            )
            return subprocess.CompletedProcess(command, 0, "", "")

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict(os.environ, environ, clear=True),
            patch.object(macos_workflow, "verify_bundle", return_value={"CFBundleShortVersionString": "0.1.0"}),
            patch.object(macos_workflow.subprocess, "run", side_effect=launch),
        ):
            macos_workflow.smoke(Path(directory), foreground)
        return commands

    def test_local_smoke_stays_in_the_background_and_offscreen(self):
        commands = self._commands({})
        self.assertEqual(len(commands), 2)
        for command in commands:
            self.assertEqual(command[:4], ["open", "-n", "-W", "-g"])
            arguments = command[command.index("--args") + 1 :]
            self.assertEqual(arguments[:2], ["--startup-smoke", "--offscreen"])

    def test_ci_and_explicit_requests_keep_the_foreground_launch(self):
        for commands in (
            self._commands({"CI": "true"}),
            self._commands({"BCR_FOREGROUND_TESTS": "1"}),
            self._commands({}, foreground=True),
        ):
            for command in commands:
                self.assertNotIn("-g", command)
                self.assertNotIn("--offscreen", command)

    def test_explicit_offscreen_overrides_ci(self):
        for command in self._commands({"CI": "true"}, foreground=False):
            self.assertIn("--offscreen", command)


if __name__ == "__main__":
    unittest.main()
