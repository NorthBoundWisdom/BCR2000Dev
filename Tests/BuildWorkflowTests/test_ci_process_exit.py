import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from configs.assert_ci_processes_exited import live_products, main


class CIProcessExitTests(unittest.TestCase):
    def test_running_product_or_xctest_is_reported_without_touching_it(self):
        table = """101 /usr/bin/python3
102 /build/app/BCRAgentConsole.app/Contents/MacOS/BCRAgentConsole
103 /build/debug/BCRProviderService
104 /build/debug/BCRProfileTool
105 /build/debug/BCRAgentConsoleTests.xctest
106 /Applications/Xcode/usr/bin/xctest
107 /usr/sbin/WindowServer
"""
        self.assertEqual([row["pid"] for row in live_products(table)], [102, 103, 104, 105, 106])
        self.assertEqual(live_products("101 /usr/bin/python3\n107 /usr/sbin/WindowServer\n"), [])

    def test_spaces_in_executable_path_do_not_hide_native_product(self):
        self.assertEqual(
            live_products("11 /owned build/BCRProviderService\n"),
            [{"pid": 11, "executable": "/owned build/BCRProviderService"}],
        )

    def test_malformed_process_evidence_fails_closed(self):
        for table in ("", "no-pid /build/BCRProviderService", "0 /build/BCRProviderService", "12"):
            with self.subTest(table=table), self.assertRaises(ValueError):
                live_products(table)

    def test_cli_reads_only_pid_and_comm_and_records_success_or_failure(self):
        for command, expected in (("/usr/bin/python3", 0), ("/build/BCRProviderService", 1)):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as root:
                output = Path(root) / "evidence.json"
                result = subprocess.CompletedProcess([], 0, stdout=f"17 {command}\n", stderr="")
                with patch("configs.assert_ci_processes_exited.subprocess.run", return_value=result) as runner:
                    with contextlib.redirect_stdout(io.StringIO()):
                        status = main(["--output", str(output)])
                self.assertEqual(status, expected)
                self.assertEqual(json.loads(output.read_text())["native_products_exited"], expected == 0)
                runner.assert_called_once_with(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True)

    def test_cli_cannot_report_success_when_process_inventory_fails(self):
        for error in (OSError("ps missing"), subprocess.CalledProcessError(1, ["ps"])):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as root:
                output = Path(root) / "evidence.json"
                with patch("configs.assert_ci_processes_exited.subprocess.run", side_effect=error):
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(main(["--output", str(output)]), 1)
                self.assertEqual(
                    json.loads(output.read_text()),
                    {"native_products_exited": False, "error": "cannot_verify_native_process_exit"},
                )
