"""Mandatory post-cut legacy proof and corruption checks, using the real Tests-only oracle."""

from __future__ import annotations

from copy import deepcopy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from configs import j3_legacy_verification

ROOT = Path(__file__).resolve().parents[2]
ORACLE = ROOT / "Tests/J3Support/verify_runtime_shadow.py"
spec = importlib.util.spec_from_file_location("j3_test_only_oracle", ORACLE)
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)


def fixture_rows():
    def snapshot(identifier):
        return {
            "input_id": identifier,
            "output_id": identifier,
            "transport_generation": None,
            "is_connected": True,
            "input_name": "fixture",
            "output_name": "fixture",
            "input_endpoints": [],
            "output_endpoints": [],
            "input_names": [],
            "output_names": [],
            "last_error": None,
        }

    def projected(identifier):
        return {
            "input_id": str(identifier),
            "output_id": str(identifier),
            "transport_generation": None,
            "is_connected": True,
            "input_name": "fixture",
            "output_name": "fixture",
            "input_origin": None,
            "output_origin": None,
        }

    one = {"kind": "controlChange", "channel": 0, "number": 81}
    two = {"kind": "controlChange", "channel": 0, "number": 82}
    scope = {"origin": "software", "endpoint": None, "mapping_revision": None, "source": None, "context": None}
    records = [
        (
            "connection.init",
            "connection",
            {"snapshot": snapshot(1), "generation": 0},
            {"snapshot": projected(1), "generation": 0},
        ),
        (
            "connection.transition",
            "connection",
            {"previous_native_snapshot": snapshot(1), "next_native_snapshot": snapshot(2)},
            {
                "route_changed": True,
                "status_changed": False,
                "invalidates_scope": True,
                "clear_pending": True,
                "became_available": True,
                "previous_generation": 0,
                "current_generation": 1,
            },
        ),
        ("connection.publish", "connection", {"snapshot": snapshot(2)}, {"snapshot": projected(2), "generation": 1}),
        (
            "binding.lookup",
            "binding",
            {
                "control": {"section": "encoder", "row": 1, "index": 1},
                "ordered_controls": [
                    {"section": "encoder", "row": 1, "index": 1},
                    {"section": "encoder", "row": 1, "index": 2},
                ],
                "ordered_assignments": ["first payload", "second payload"],
            },
            {"reference": 0, "result": "first payload"},
        ),
        (
            "scope.transport.accepted",
            "connection",
            {
                "captured_source": "hardware",
                "current_source": "hardware",
                "captured_epoch": "epoch",
                "current_epoch": "epoch",
                "captured_mapping": 1,
                "current_mapping": 1,
                "checks_endpoint": True,
                "captured_endpoint": None,
                "current_endpoint": None,
                "captured_queue": None,
                "current_queue": 0,
            },
            {"matches": True},
        ),
        ("index.init", "index", {}, {"ids": [], "scopes": [], "count": 0, "removed": []}),
        (
            "index.upsert",
            "index",
            {"id": one, "scope": scope},
            {"ids": [one], "scopes": [scope], "count": 1, "removed": []},
        ),
        (
            "index.upsert",
            "index",
            {"id": two, "scope": scope},
            {"ids": [one, two], "scopes": [scope, scope], "count": 2, "removed": []},
        ),
        (
            "index.removeFirst",
            "index",
            {"amount": 1, "at": 123},
            {"ids": [two], "scopes": [scope], "count": 1, "removed": [one]},
        ),
    ]
    rows = [
        {
            "sequence": i + 1,
            "record_kind": "operation",
            "operation": operation,
            "owner": owner,
            "input": inputs,
            "actual": actual,
        }
        for i, (operation, owner, inputs, actual) in enumerate(records)
    ]
    # JSONL parsing never aliases an operation input with its separately emitted result.
    return json.loads(json.dumps(rows))


def write_rows(directory, rows):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "operations.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))


class J3LegacyReplayTests(unittest.TestCase):
    def replay(self, rows):
        with tempfile.TemporaryDirectory() as directory:
            write_rows(Path(directory), rows)
            return oracle.verify(Path(directory))

    def test_actual_only_rows_require_no_production_native_or_comparison_branch(self):
        proof = self.replay(fixture_rows())
        self.assertEqual(proof["actual_operations"], 9)
        self.assertEqual(proof["independent_legacy_replay_differences"], 0)

    def test_actual_route_generation_and_status_corruption_fail(self):
        for field, replacement in [("current_generation", 2), ("status_changed", True), ("clear_pending", False)]:
            with self.subTest(field=field), self.assertRaises(AssertionError):
                rows = fixture_rows()
                rows[1]["actual"][field] = replacement
                self.replay(rows)

    def test_actual_binding_scope_order_and_optional_identity_corruption_fail(self):
        for mutation in ["binding", "scope", "order", "optional"]:
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                rows = deepcopy(fixture_rows())
                original_inputs = deepcopy([row["input"] for row in rows])
                if mutation == "binding":
                    rows[3]["actual"] = {"reference": 1, "result": "second payload"}
                elif mutation == "scope":
                    rows[4]["actual"]["matches"] = False
                elif mutation == "order":
                    rows[7]["actual"]["ids"].reverse()
                else:
                    rows[7]["actual"]["scopes"][0]["source"] = "hardware"
                self.assertEqual([row["input"] for row in rows], original_inputs)
                self.replay(rows)

    def test_original_native_drain_bounds_cannot_be_relaxed_to_clamped_slicing(self):
        for amount in [-1, 3]:
            with self.subTest(amount=amount), self.assertRaises(AssertionError):
                rows = fixture_rows()
                rows[-1]["input"]["amount"] = amount
                self.replay(rows)

    def test_no_operation_missing_sequence_and_unknown_operation_fail(self):
        for rows in [[], [{**fixture_rows()[0], "sequence": 2}], [{**fixture_rows()[0], "operation": "unknown"}]]:
            with self.subTest(rows=rows), self.assertRaises(AssertionError):
                self.replay(rows)


class J3MandatoryWorkflowTests(unittest.TestCase):
    def setup_root(self, root):
        (root / "Package.swift").write_text('.product(name: "SurfaceBindingContext", package: "ControlSurfaceKit")')
        tap = root / "Sources/BCRSurfaceDomain/SurfaceKernelTrace.swift"
        tap.parent.mkdir(parents=True)
        tap.write_text("// Test fixture for the runtime-tap presence gate\n")
        target = root / "Tests/J3Support/verify_runtime_shadow.py"
        target.parent.mkdir(parents=True)
        shutil.copy2(ORACLE, target)
        run = root / "run"
        run.mkdir()
        return run

    def test_required_real_tap_or_oracle_missing_is_fatal(self):
        for path in ["Sources/BCRSurfaceDomain/SurfaceKernelTrace.swift", "Tests/J3Support/verify_runtime_shadow.py"]:
            with (
                self.subTest(path=path),
                tempfile.TemporaryDirectory() as temporary,
                patch.dict(os.environ, {}, clear=True),
            ):
                root = Path(temporary)
                run = self.setup_root(root)
                (root / path).unlink()
                with self.assertRaises(RuntimeError), j3_legacy_verification.capture(root, run):
                    self.fail("missing mandatory legacy verification was accepted")

    def test_workflow_verifies_real_oracle_and_restores_default_off_environment(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            root = Path(temporary)
            run = self.setup_root(root)
            with j3_legacy_verification.capture(root, run) as trace:
                self.assertEqual(os.environ[j3_legacy_verification.TRACE_ENV], str(trace))
                write_rows(trace, fixture_rows())
                j3_legacy_verification.verify(root, run, trace, 10)
            self.assertNotIn(j3_legacy_verification.TRACE_ENV, os.environ)
            self.assertTrue((run / "kernel-legacy-proof.json").is_file())

    def test_mismatch_reused_evidence_empty_trace_and_missing_core_are_fatal(self):
        for mutation in ["mismatch", "empty", "coverage", "reused"]:
            with (
                self.subTest(mutation=mutation),
                tempfile.TemporaryDirectory() as temporary,
                patch.dict(os.environ, {}, clear=True),
            ):
                root = Path(temporary)
                run = self.setup_root(root)
                if mutation == "reused":
                    reused = root / "existing"
                    write_rows(reused, fixture_rows())
                    os.environ[j3_legacy_verification.TRACE_ENV] = str(reused)
                    with self.assertRaises(RuntimeError), j3_legacy_verification.capture(root, run):
                        self.fail("reused evidence was accepted")
                    continue
                with j3_legacy_verification.capture(root, run) as trace:
                    rows = fixture_rows()
                    if mutation == "mismatch":
                        rows[3]["actual"]["reference"] = 1
                    if mutation == "empty":
                        rows = []
                    if mutation == "coverage":
                        rows = rows[:1]
                    write_rows(trace, rows)
                    with self.assertRaises(RuntimeError):
                        j3_legacy_verification.verify(root, run, trace, 10)
