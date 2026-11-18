import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from configs import j4_shadow_verification as gate


class J4WorkflowIntegrityTests(unittest.TestCase):
    def fixture(self, base):
        root = Path(base) / "repo"
        root.mkdir()
        (root / "Package.swift").write_text('.product(name: "SurfaceFeedbackPlanning", package: "ControlSurfaceKit")')
        for name in [
            "Sources/BCRSurfaceDomain/FeedbackJ4Trace.swift",
            "Sources/BCRSurfaceDomain/FeedbackRuntime.swift",
            "Tests/BCRAgentCoreTests/J4SchedulerArchiveReplayTests.swift",
            "Tests/BCRAgentCoreTests/J4SessionSchedulerArchiveReplayTests.swift",
        ]:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("test fixture")
        run = Path(base) / "run"
        run.mkdir()
        return root, run

    def test_fresh_capture_refuses_reuse_and_restores_environment(self):
        with tempfile.TemporaryDirectory() as base:
            root, run = self.fixture(base)
            with patch.dict(os.environ, {}, clear=False):
                previous = os.environ.pop(gate.TRACE_ENV, None)
                try:
                    with gate.capture(root, run) as trace:
                        self.assertEqual(os.environ[gate.TRACE_ENV], str(trace))
                        self.assertTrue((trace / "run-marker.json").is_file())
                    self.assertNotIn(gate.TRACE_ENV, os.environ)
                    with patch.dict(os.environ, {gate.TRACE_ENV: str(trace)}):
                        with self.assertRaisesRegex(RuntimeError, "reused"):
                            with gate.capture(root, run):
                                pass
                finally:
                    if previous is not None:
                        os.environ[gate.TRACE_ENV] = previous

    def test_missing_candidate_or_runtime_tap_is_a_required_failure(self):
        with tempfile.TemporaryDirectory() as base:
            root, run = self.fixture(base)
            (root / "Tests/BCRAgentCoreTests/J4SessionSchedulerArchiveReplayTests.swift").unlink()
            with self.assertRaisesRegex(RuntimeError, "requires actual hooks"):
                with gate.capture(root, run):
                    pass

    def test_original_session_envelope_rejects_version_type_missing_extra_and_duplicate_keys(self):
        row = {
            "schema_version": 1,
            "owner": "real-owner",
            "ordinal": "1",
            "operation": "clear_queue",
            "arguments": {},
            "context": {"causal_ordinal": "1"},
        }
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / "session-input.jsonl"
            path.write_text(json.dumps(row) + "\n")
            self.assertEqual(gate.validate_session_input(path), 1)
            invalid = []
            for version in [99, True, 1.0, "1", None]:
                invalid.append(json.dumps({**row, "schema_version": version}))
            missing = dict(row)
            del missing["schema_version"]
            invalid += [json.dumps(missing), json.dumps({**row, "extra": None})]
            invalid += [
                '{"schema_version":1,' + json.dumps(row)[1:],
                '{"schema_vers\\u0069on":1,' + json.dumps(row)[1:],
            ]
            for text in invalid:
                with self.subTest(text=text):
                    path.write_text(text + "\n")
                    with self.assertRaises(RuntimeError):
                        gate.validate_session_input(path)

    def test_merged_session_row_checks_match_independent_entry_and_fail_closed(self):
        row = {
            "schema_version": 1,
            "owner": "owner",
            "ordinal": "1",
            "operation": "clear_queue",
            "arguments": {},
            "context": {"causal_ordinal": "1"},
        }
        variants = [{**row, "schema_version": value} for value in [True, 1.0, 2, "1", None]]
        variants += [
            {**row, "operation": "unknown"},
            {**row, "arguments": []},
            {**row, "context": []},
            {**row, "owner": ""},
            {**row, "ordinal": "01"},
            {**row, "extra": None},
        ]
        missing = dict(row)
        del missing["arguments"]
        variants.append(missing)
        invalid = [json.dumps(value) for value in variants]
        invalid += [
            '{"schema_version":1,' + json.dumps(row)[1:],
            '{"schema_vers\\u0069on":1,' + json.dumps(row)[1:],
            json.dumps(row).replace('"arguments": {}', '"arguments": {"v":1e309}'),
        ]
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / "session-input-123.jsonl"
            (Path(base) / "scheduler-input-123.jsonl").write_text("")
            path.write_text(json.dumps(row) + "\n")
            self.assertEqual(gate.validate_session_input(path), 1)
            self.assertEqual(gate.validate_process_inputs(path)["shared_causal_records"], 1)
            for raw in invalid:
                with self.subTest(raw=raw):
                    path.write_text(raw + "\n")
                    with self.assertRaises(RuntimeError):
                        gate.validate_session_input(path)
                    with self.assertRaises(RuntimeError):
                        gate.validate_process_inputs(path)

    def test_original_source_namespaces_causal_union_and_unique_output_coverage(self):
        with tempfile.TemporaryDirectory() as base:
            root = Path(base)

            def event(owner, ordinal, operation, causal, arguments):
                return {
                    "schema_version": 1,
                    "owner": owner,
                    "ordinal": str(ordinal),
                    "operation": operation,
                    "arguments": arguments,
                    "context": {"causal_ordinal": str(causal)},
                }

            session = [
                event("session", 1, "attach_scheduler", 1, {"scheduler_owner": "queue"}),
                event("session", 2, "message_intent", 3, {}),
            ]
            queue = [event("queue", 1, "initialize", 2, {})]
            output = {"schema_version": 1, "owner": "session", "ordinal": "2", "output": {"disposition": "send"}}
            native_queue = {
                "schema_version": 1,
                "owner": "queue",
                "ordinal": "1",
                "output": {
                    k: None
                    for k in ["pending", "drained", "tokens", "refill", "retry", "removed_keys", "replaced_keys"]
                },
            }

            def write(family, rows):
                (root / (family + "-123.jsonl")).write_text("".join(json.dumps(v) + "\n" for v in rows))

            write("session-input", session)
            write("scheduler-input", queue)
            write("session-native", [output])
            write("scheduler-native", [native_queue])
            path = root / "session-input-123.jsonl"
            self.assertEqual(gate.validate_process_inputs(path)["shared_causal_records"], 3)
            self.assertTrue(gate.validate_process_outputs(path)["session-native"]["complete"])
            write("session-input", session[1:])
            with self.assertRaisesRegex(RuntimeError, "cursor gap"):
                gate.validate_process_inputs(path)
            write("session-input", session)
            write("session-native", [output, output])
            with self.assertRaisesRegex(RuntimeError, "Duplicate"):
                gate.validate_process_outputs(path)
            write("session-native", [])
            with self.assertRaisesRegex(RuntimeError, "Missing"):
                gate.validate_process_outputs(path)

    def test_duplicate_and_nonfinite_scheduler_source_json_is_rejected(self):
        for raw in ['{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}', '{"a":1e309}']:
            with self.assertRaises(RuntimeError):
                gate._load(raw)
        with self.assertRaises(RuntimeError):
            gate._load('{"value":' + "1" + "0" * 400 + "}")


if __name__ == "__main__":
    unittest.main()
