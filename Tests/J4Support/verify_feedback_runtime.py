"""Independent native3b feedback leaves, Tests only. No production/Core decision helper imports."""

from __future__ import annotations

from collections import Counter
from pathlib import Path
import json
import copy
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from configs.j4_shadow_verification import (
    _load,
    _same,
    _source_cursor,
    validate_process_inputs,
    validate_process_outputs,
)

REFERENCE = "3b5725be4aa7466590f58b16d21913fc3e1ef077"
OPERATIONS = {
    "capture_generation",
    "capture_dispatch",
    "generation_authorization",
    "dispatch",
    "authorization",
    "preflight",
    "receipt",
    "summary",
    "boundary_before_receipt_hook",
    "boundary_after_receipt_hook",
    "native_gate_rejected_before_full_preflight",
}
OBSERVATIONS = {
    "boundary_before_receipt_hook",
    "boundary_after_receipt_hook",
    "native_gate_rejected_before_full_preflight",
}


def endpoint(raw):
    return {
        "endpoint_id": None if raw is None or raw["endpoint_id"] == "unknown" else raw["endpoint_id"],
        "device_id": None if raw is None else raw["device_id"],
        "connection_generation": "0" if raw is None else raw["connection_generation"],
        "transport_origin": "unknown" if raw is None else raw["provenance"],
    }


def scope(evidence):
    return {
        "source": "simulation" if evidence["source"] == "mock" else "hardware",
        "context_id": "surface.lifecycle",
        "generation": "input-epoch:" + evidence["context"]["generation"],
        "mapping_revision": evidence["context"]["mapping_generation"],
        "endpoint": None if evidence["endpoint"] is None else endpoint(evidence["endpoint"]),
    }


def plan(arguments, operation):
    message, control = arguments["message"], arguments["control"]
    kind = "note" if message["case"] in ("noteOn", "noteOff") else message["case"]
    reference = kind + "." + str(message["channel"]) + "." + str(message["number"])
    expected_control = None
    if operation == "capture_dispatch":
        expected_control = next(
            (
                x["control"]
                for x in arguments["hardware_map"]["entries"]
                if _same(x["midi"], {"kind": kind, "channel": message["channel"], "number": message["number"]})
            ),
            None,
        )
    if not _same(control, expected_control):
        raise RuntimeError("Native3b independent ordered map/control mismatch")
    target = (
        "midi." + reference
        if control is None
        else control["section"] + "." + str(control["row"]) + "." + str(control["index"])
    )
    physical = target
    if control is not None and control["section"] in ("pushEncoder", "pushEncoderButton"):
        physical = ("pushEncoder.rotate." if control["section"] == "pushEncoder" else "pushEncoder.press.") + str(
            control["index"]
        )
    evidence = arguments["evidence"]
    return {
        "reference": reference,
        "payload": message,
        "origin": arguments["origin"],
        "scope": scope(evidence),
        "source": "simulation" if evidence["source"] == "mock" else "hardware",
        "endpoint_evidence": endpoint(evidence["endpoint"]),
        "captured_evidence": evidence,
        "target_id": target,
        "affected_elements": [] if control is None else [physical],
        "classification": "display",
        "side_effects": [],
        "required_directions": ["display"],
        "delivery_mode": "coalescible" if arguments["timing"] == "coalesced" else "direct",
    }


def permission(evidence, generation=False):
    if generation:
        allowed = not (evidence["source"] == "hardware" and evidence["hardware_output"] == "observe")
        reason = "observe"
    else:
        raw = evidence["parameter_context"]
        allowed = raw is None or (
            raw["source"] == evidence["source"]
            and raw["generation"] == evidence["context"]["generation"]
            and raw["mapping_revision"] == evidence["context"]["mapping_generation"]
            and raw["allows_display"]
        )
        reason = "parameter_context"
    return allowed, {"case": "granted", "directions": ["display"]} if allowed else {"case": "denied", "reason": reason}


def same_native_scope(captured, current):
    return (
        captured["source"] == current["source"]
        and captured["context"]["generation"] == current["context"]["generation"]
        and captured["context"]["mapping_generation"] == current["context"]["mapping_generation"]
        and _same(captured["endpoint"], current["endpoint"])
    )


def verify(trace: Path, output: Path, require_families=True, mutation=None):
    """Read original inputs/external IO outcomes; independently compare every actual Core result."""
    output.mkdir(parents=True, exist_ok=False)
    files = sorted(trace.glob("feedback-actual-*.jsonl"))
    if not files:
        raise RuntimeError("Missing Core-primary actual feedback family")
    total, observed, differences = 0, 0, 0
    operations = Counter()
    mutated = False
    mutation_operations = {
        "capture": "capture_generation",
        "dispatch": "dispatch",
        "authorization": "authorization",
        "preflight": "preflight",
        "receipt": "receipt",
        "summary": "summary",
    }
    for path in files:
        suffix = path.name.removeprefix("feedback-actual-")
        session_source = trace / ("session-input-" + suffix)
        validate_process_inputs(session_source)
        external = {}
        for line in (trace / ("session-input-" + suffix)).open():
            row = _load(line)
            if row["operation"] == "actual_boundary_result":
                args = row["arguments"]
                capture = args["plan_capture"]
                if type(capture) is not str or capture in external or args["entered"] is not True:
                    raise RuntimeError("Actual IO/capture association invalid")
                external[capture] = args
        captures = {}
        cursor = 0
        seen_receipts = set()
        with (
            (output / ("comparison-" + suffix)).open("w") as compared,
            (output / ("differences-" + suffix)).open("w") as delta,
        ):
            for line in path.open():
                row = _load(line)
                if (
                    set(row) != {"schema_version", "owner", "ordinal", "operation", "input", "actual"}
                    or type(row["schema_version"]) is not int
                    or row["schema_version"] != 1
                ):
                    raise RuntimeError("Unknown actual Core feedback envelope")
                _source_cursor(row)
                if type(row["ordinal"]) is not str or row["ordinal"] != str(cursor + 1):
                    raise RuntimeError("Core-primary per-PID cursor missing/duplicate/reordered")
                cursor += 1
                operation, arguments = row["operation"], row["input"]
                if operation not in OPERATIONS:
                    raise RuntimeError("Unknown Core-primary feedback operation")
                operations[operation] += 1
                if operation.startswith("capture_"):
                    if set(arguments) != {"message", "origin", "timing", "control", "hardware_map", "evidence"}:
                        raise RuntimeError("Missing native3b plan input fields")
                    expected = plan(arguments, operation)
                    captures[row["ordinal"]] = (row["owner"], expected, arguments)
                elif operation == "summary":
                    if (
                        set(arguments) != {"deliveries", "completion_error_present"}
                        or type(arguments["completion_error_present"]) is not bool
                    ):
                        raise RuntimeError("Unknown receipt summary input shape")
                    values = arguments["deliveries"]
                    if type(values) is not list or any(
                        x not in (None, "sent", "failed", "disconnected", "suppressed") for x in values
                    ):
                        raise RuntimeError("Unknown original delivery projection")
                    accepted = sum(x == "sent" for x in values)
                    rejected = sum(x == "failed" for x in values)
                    expected = {
                        "all_accepted": bool(values) and all(x == "sent" for x in values),
                        "any_accepted": any(x == "sent" for x in values),
                        "attempt_count": accepted + rejected,
                        "accepted_count": accepted,
                        "rejected_count": rejected,
                        "not_attempted_count": len(values) - accepted - rejected,
                    }
                else:
                    capture = arguments.get("plan_capture")
                    if type(capture) is not str or capture not in captures or captures[capture][0] != row["owner"]:
                        raise RuntimeError("Original capture/actual operation binding missing")
                    _, native_plan, native_arguments = captures[capture]
                    if not _same(arguments["plan"], native_plan):
                        raise RuntimeError("Whole actual plan transferred/changed from original inputs")
                    evidence = native_plan["captured_evidence"]
                    if operation in ("authorization", "generation_authorization"):
                        allowed, grant = permission(evidence, operation == "generation_authorization")
                        if not _same(arguments["authorization"], grant) or arguments["requirements"] != ["display"]:
                            raise RuntimeError("Original authorization facts/whole directions changed")
                        expected = {"allowed": allowed}
                    elif operation == "dispatch":
                        can = arguments["can_coalesce"]
                        policy = arguments["native_feedback_policy"]
                        if (
                            set(policy) != {"enabled", "messages_per_second", "burst", "error_cooldown"}
                            or type(policy["enabled"]) is not bool
                        ):
                            raise RuntimeError("Missing complete native feedback policy")
                        expected_can = (
                            evidence["source"] == "hardware"
                            and policy["enabled"]
                            and evidence["connection"]["output_name"] is not None
                        )
                        if type(can) is not bool or can != expected_can:
                            raise RuntimeError("Invalid independent original source/enabled/connection coalescing fact")
                        expected = {
                            "decision": "enqueue" if can and native_arguments["timing"] == "coalesced" else "send"
                        }
                    elif operation == "preflight":
                        if not _same(arguments["proof_plan"], native_plan) or not _same(
                            arguments["native_snapshot"]["evidence"], evidence
                        ):
                            raise RuntimeError("Full proof plan/native capture mismatch")
                        device = arguments["native_snapshot"]["device_connection"]
                        if not _same(arguments["current_native_snapshot"]["device_connection"], device):
                            raise RuntimeError("Original one getter fact was changed")
                        allowed, grant = permission(evidence)
                        if (
                            not allowed
                            or not _same(arguments["authorization"], grant)
                            or arguments["required_directions"] != ["display"]
                        ):
                            raise RuntimeError("Preflight reached despite original early authorization rejection")
                        safety = (
                            {"case": "passed"}
                            if device["output_name"] is not None
                            else {"case": "rejected", "reason": "disconnected"}
                        )
                        if not _same(arguments["native_safety"], safety) or not _same(
                            arguments["current_scope"], scope(arguments["current_native_snapshot"]["evidence"])
                        ):
                            raise RuntimeError("Native safety/current scope input changed")
                        allowed = device["output_name"] is not None
                        expected = {
                            "allowed": allowed,
                            "result": {"case": "permitted"}
                            if allowed
                            else {"case": "rejected", "reason": "native_rejected", "native_reason": "disconnected"},
                        }
                    elif operation == "receipt":
                        if capture in seen_receipts:
                            raise RuntimeError("Duplicate original invocation receipt")
                        seen_receipts.add(capture)
                        result = arguments["result"]
                        io = external.get(capture)
                        if io is not None:
                            actual_state = io["result"]["state"]
                            wanted = (
                                {"case": "accepted"}
                                if actual_state == "accepted"
                                else {"case": "rejected", "reason": io["result"]["reason"]}
                            )
                            if (
                                not _same(result, wanted)
                                or not _same(io["message"], native_plan["payload"])
                                or not _same(io["captured_evidence"], evidence)
                            ):
                                raise RuntimeError("Actual native send outcome was not preserved in Core receipt")
                        elif result["case"] != "notAttempted":
                            raise RuntimeError("Invented transport attempt without original send boundary")
                        attempted = io is not None
                        successful = attempted and io["result"]["state"] == "accepted"
                        current = None
                        if arguments["current_scope"] is not None:
                            if arguments["current_evidence"] is None or not _same(
                                arguments["current_scope"], scope(arguments["current_evidence"])
                            ):
                                raise RuntimeError("Original receipt current facts missing/changed")
                            current = same_native_scope(evidence, arguments["current_evidence"])
                        expected = {
                            "attempted": attempted,
                            "successful": successful,
                            "current": current,
                            "accepted_in_current_scope": None if current is None else successful and current,
                        }
                        if (
                            arguments["attempt_layer"] != "SurfaceDevice.send admission call"
                            or arguments["underlying_native_transport_attempt"] is not None
                            or arguments["physical_bytes_written"] is not None
                            or arguments["actual_observation"] is not False
                        ):
                            raise RuntimeError("Actual IO layer was conflated with physical observation")
                    elif operation == "native_gate_rejected_before_full_preflight":
                        expected = {"full_preflight_executed": False}
                    else:
                        expected = {}
                actual = row["actual"]
                if mutation_operations.get(mutation) == operation and not mutated:
                    actual = copy.deepcopy(actual)
                    if mutation == "capture":
                        actual["payload"]["value"] = int(actual["payload"]["value"]) ^ 1
                    elif mutation == "dispatch":
                        actual["decision"] = "enqueue" if actual["decision"] == "send" else "send"
                    elif mutation in ("authorization", "preflight"):
                        actual["allowed"] = not actual["allowed"]
                    elif mutation == "receipt":
                        actual["successful"] = not actual["successful"]
                    elif mutation == "summary":
                        actual["accepted_count"] += 1
                    mutated = True
                record = {
                    "owner": row["owner"],
                    "ordinal": row["ordinal"],
                    "operation": operation,
                    "original_input": arguments,
                    "legacy_expected": expected,
                    "actual_core": actual,
                }
                compared.write(json.dumps(record, separators=(",", ":"), ensure_ascii=False) + "\n")
                if not _same(expected, actual):
                    differences += 1
                    delta.write(json.dumps(record, separators=(",", ":"), ensure_ascii=False) + "\n")
                if operation in OBSERVATIONS:
                    observed += 1
                else:
                    total += 1
        validate_process_outputs(session_source)
        if set(external) - seen_receipts:
            raise RuntimeError("Missing receipt for actual send boundary")
    if (
        require_families
        and {
            "capture_generation",
            "capture_dispatch",
            "generation_authorization",
            "dispatch",
            "authorization",
            "preflight",
            "receipt",
            "summary",
        }
        - operations.keys()
    ):
        raise RuntimeError("Missing actual Core-primary feedback algorithm family")
    if total == 0 or mutation is not None and not mutated:
        raise RuntimeError("Empty/missing actual Core-primary comparison")
    report = {
        "reference_git": REFERENCE,
        "core_primary": True,
        "algorithm_comparison_rows": total,
        "observation_rows": observed,
        "operations": dict(operations),
        "differences": differences,
        "native_output_used_as_state": False,
        "physical_observation_claimed": False,
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if differences:
        raise RuntimeError("Independent native3b feedback mismatch: " + str(output))
    return report


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mutate", choices=("capture", "dispatch", "authorization", "preflight", "receipt", "summary"))
    args = parser.parse_args()
    verify(args.trace, args.output, mutation=args.mutate)
