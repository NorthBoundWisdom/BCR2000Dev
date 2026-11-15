import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import sys
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "candidate_probe", ROOT / "Support/NativeDiagnostics/f_candidate_probe.py"
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class CandidateProbePaginationTests(unittest.TestCase):
    def display(self, *, latest=1, dropped=0):
        class Surface:
            def __init__(self, *args, **kwargs):
                self.expected = {"mapping_revision": "candidate", "epoch": "e"}

            def discover(self, **kwargs):
                return {"expected": self.expected}

            def snapshot(self):
                return {"link": {"state": "connected"}, "latest_input_sequence": "0"}

            def feedback(self, *args):
                pass

        class Provider:
            def __init__(self, *args):
                self.first = True

            def call(self, *args):
                if self.first:
                    self.first = False
                    return {"generation": "g", "latest_sequence": 0, "reset": False, "dropped": 0, "events": []}
                return {
                    "generation": "g",
                    "latest_sequence": latest,
                    "reset": False,
                    "dropped": dropped,
                    "events": [
                        {
                            "sequence": 1,
                            "kind": "feedback.sent",
                            "payload": {
                                "midi": {"kind": "controlChange", "channel": 0, "number": 67},
                                "raw_value": 127,
                            },
                        }
                    ],
                }

        read_fd, write_fd = os.pipe()
        os.write(write_fd, secrets.token_hex(32).encode())
        os.close(write_fd)
        result = io.StringIO()
        with os.fdopen(read_fd) as credential_pipe:
            with (
                mock.patch.object(
                    sys,
                    "argv",
                    [
                        "probe",
                        "--sdk",
                        "unused",
                        "--url",
                        "unused",
                        "--instance",
                        "test",
                        "--mapping-revision",
                        "candidate",
                        "--action",
                        "display",
                        "--value",
                        "on",
                        "--confirm-attended-display",
                    ],
                ),
                mock.patch.object(sys, "stdin", credential_pipe),
                mock.patch.dict(
                    sys.modules,
                    {
                        "surface_control": types.SimpleNamespace(Client=Surface),
                        "bcr_provider": types.SimpleNamespace(Client=Provider),
                    },
                ),
                contextlib.redirect_stdout(result),
            ):
                try:
                    probe.main()
                    status = 0
                except SystemExit as error:
                    status = error.code
        return status, json.loads(result.getvalue())

    def test_display_rejects_incomplete_first_page_even_if_it_has_one_matching_send(self):
        status, result = self.display(latest=2)
        self.assertEqual(status, 1)
        self.assertFalse(result["passed"])

    def test_display_rejects_dropped_events(self):
        status, result = self.display(dropped=1)
        self.assertEqual(status, 1)
        self.assertFalse(result["passed"])

    def test_display_accepts_one_complete_matching_send(self):
        status, result = self.display()
        self.assertEqual(status, 0)
        self.assertTrue(result["passed"])
