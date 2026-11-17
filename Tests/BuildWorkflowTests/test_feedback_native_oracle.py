import copy
import json
from pathlib import Path
import tempfile
import unittest

from Tests.J4Support import verify_feedback_runtime as legacy


class FeedbackNativeOracleTests(unittest.TestCase):
    def fixture(self, root):
        evidence = {
            "source": "mock",
            "context": {"generation": "g", "mapping_generation": "0", "known_device_context_id": None},
            "endpoint": None,
            "expected_endpoint": None,
            "expected_mapping": None,
            "connection": {
                "input_id": None,
                "output_id": None,
                "transport_generation": None,
                "input_name": None,
                "output_name": None,
                "input_names": [],
                "output_names": [],
                "input_endpoints": [],
                "output_endpoints": [],
                "last_error": None,
                "is_connected": False,
            },
            "parameter_context": None,
            "publication_revision": None,
            "queue_generation": "0",
            "hardware_output": "write",
            "receipt_identity": None,
            "accepted_hook_present": False,
            "legacy_queued": None,
            "resolved_generation_timing": "coalesced",
        }
        message = {"case": "controlChange", "channel": 1, "number": 81, "value": 64}
        facts = {
            "message": message,
            "origin": "external",
            "timing": "coalesced",
            "control": None,
            "hardware_map": {"version": 7, "entries": []},
            "evidence": evidence,
        }
        plan = {
            "reference": "controlChange.1.81",
            "payload": message,
            "origin": "external",
            "scope": {
                "source": "simulation",
                "context_id": "surface.lifecycle",
                "generation": "input-epoch:g",
                "mapping_revision": "0",
                "endpoint": None,
            },
            "source": "simulation",
            "endpoint_evidence": {
                "endpoint_id": None,
                "device_id": None,
                "connection_generation": "0",
                "transport_origin": "unknown",
            },
            "captured_evidence": evidence,
            "target_id": "midi.controlChange.1.81",
            "affected_elements": [],
            "classification": "display",
            "side_effects": [],
            "required_directions": ["display"],
            "delivery_mode": "coalescible",
        }
        rows = [
            {
                "schema_version": 1,
                "owner": "original-owner",
                "ordinal": "1",
                "operation": "capture_generation",
                "input": facts,
                "actual": copy.deepcopy(plan),
            }
        ]
        for family in ("session-input", "session-native", "scheduler-input", "scheduler-native"):
            (root / (family + "-123.jsonl")).write_text("")
        return rows

    def run_rows(self, rows, root, name):
        (root / "feedback-actual-123.jsonl").write_text("".join(json.dumps(v) + "\n" for v in rows))
        return legacy.verify(root, root / name, require_families=False)

    def test_actual_only_full_payload_origin_target_optional_evidence_are_independent(self):
        with tempfile.TemporaryDirectory() as base:
            root = Path(base)
            rows = self.fixture(root)
            self.assertEqual(self.run_rows(rows, root, "valid")["differences"], 0)
            for i, mutate in enumerate(
                [
                    lambda x: x["payload"].__setitem__("value", 65),
                    lambda x: x.__setitem__("origin", "software"),
                    lambda x: x.__setitem__("target_id", "other"),
                    lambda x: x["captured_evidence"].__setitem__("expected_mapping", "0"),
                    lambda x: x["payload"].__setitem__("channel", True),
                ]
            ):
                invalid = copy.deepcopy(rows)
                mutate(invalid[0]["actual"])
                with self.subTest(index=i), self.assertRaisesRegex(RuntimeError, "Independent native3b"):
                    self.run_rows(invalid, root, "wrong-" + str(i))

    def test_actual_header_types_closed_fields_and_original_cursor_cannot_be_faked(self):
        with tempfile.TemporaryDirectory() as base:
            root = Path(base)
            rows = self.fixture(root)
            invalid = []
            for version in (True, 1.0, 2):
                invalid.append([{**copy.deepcopy(rows[0]), "schema_version": version}])
            invalid += [
                [{**copy.deepcopy(rows[0]), "extra": None}],
                [{**copy.deepcopy(rows[0]), "ordinal": "2"}],
                rows + copy.deepcopy(rows),
            ]
            for i, value in enumerate(invalid):
                with self.subTest(index=i), self.assertRaisesRegex(RuntimeError, "envelope|cursor"):
                    self.run_rows(value, root, "invalid-" + str(i))

    def test_actual_tap_and_tests_oracle_are_required_by_workflow(self):
        from configs import j4_shadow_verification as gate

        with tempfile.TemporaryDirectory() as base:
            root = Path(base)
            with self.assertRaisesRegex(RuntimeError, "Missing Core-primary"):
                legacy.verify(root, root / "output")
        source = Path(gate.__file__).read_text()
        self.assertIn('verify_actual_feedback(trace, directory / "feedback-native-legacy")', source)
        self.assertIn('"Tests/J4Support/verify_feedback_runtime.py"', source)


if __name__ == "__main__":
    unittest.main()
