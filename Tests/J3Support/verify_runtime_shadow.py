#!/usr/bin/env python3
"""Replay native J3 leaves independently from actual-operation traces.

Oracle: BCR2000Dev 36692f1422b0c3952f9048847a0bafd65421bc72.
Connection: SurfaceSession.handleConnection route/status/generation predicate;
publication remains a separate caller operation at the original boundary.
Index: FeedbackScheduler enqueue/cancel/drain identity removal/clear, with no
payload, rate, clock or cooldown implementation. Binding: first ordered control
match. Scope: exact native source/epoch/mapping/endpoint and optional queue gate.
Never seed state from native/candidate result IDs; only init and real inputs.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path


def selected_origin(snapshot, direction):
    identifier = snapshot[direction + "_id"]
    return next((row["provenance"] for row in snapshot[direction + "_endpoints"] if row["id"] == identifier), None)


def route(snapshot):
    return (
        snapshot["transport_generation"],
        snapshot["input_id"],
        snapshot["output_id"],
        snapshot["input_name"],
        snapshot["output_name"],
        selected_origin(snapshot, "input"),
        selected_origin(snapshot, "output"),
    )


def projected(snapshot):
    return {
        "input_id": None if snapshot["input_id"] is None else str(snapshot["input_id"]),
        "output_id": None if snapshot["output_id"] is None else str(snapshot["output_id"]),
        "transport_generation": snapshot["transport_generation"],
        "is_connected": snapshot["is_connected"],
        "input_name": snapshot["input_name"],
        "output_name": snapshot["output_name"],
        "input_origin": selected_origin(snapshot, "input"),
        "output_origin": selected_origin(snapshot, "output"),
    }


def key(identifier):
    return json.dumps(identifier, sort_keys=True, separators=(",", ":"))


def verify(directory):
    counts, outcomes = Counter(), Counter()
    comparisons = catalogues_total = 0
    files = sorted(directory.glob("*.jsonl"))
    assert files, "No actual runtime operation files"
    for path in files:
        catalogues, indexes, connections = {}, {}, {}
        sequence = 0
        with path.open() as source:
            for line_number, line in enumerate(source, 1):
                row = json.loads(line)
                assert row["sequence"] == sequence + 1, (path, line_number, "sequence gap")
                sequence += 1
                if row.get("record_kind") == "catalogue":
                    identifier = row["catalogue_id"]
                    assert identifier not in catalogues, "Duplicate catalogue identity"
                    catalogues[identifier] = row["value"]
                    catalogues_total += 1
                    continue
                inputs = {
                    k: catalogues[v["$catalogue"]] if isinstance(v, dict) and set(v) == {"$catalogue"} else v
                    for k, v in row["input"].items()
                }
                operation, owner = row["operation"], row["owner"]
                counts[operation] += 1
                if "actual" in row:
                    actual = row["actual"]
                else:
                    # Preserve read-only verification of the pre-cut shadow artifacts.
                    assert row["typed_matches"] and row["matches"] and row["native"] == row["candidate"], (
                        path,
                        line_number,
                        "inline pre-cut typed comparison differs",
                    )
                    actual = row["candidate"]
                if operation == "binding.lookup":
                    reference = next(
                        (i for i, control in enumerate(inputs["ordered_controls"]) if control == inputs["control"]),
                        None,
                    )
                    expected = {
                        "reference": reference,
                        "result": None if reference is None else inputs["ordered_assignments"][reference],
                    }
                elif operation.startswith("scope."):
                    match = (
                        inputs["captured_source"] == inputs["current_source"]
                        and inputs["captured_epoch"] == inputs["current_epoch"]
                        and inputs["captured_mapping"] == inputs["current_mapping"]
                        and (not inputs["checks_endpoint"] or inputs["captured_endpoint"] == inputs["current_endpoint"])
                        and (inputs["captured_queue"] is None or inputs["captured_queue"] == inputs["current_queue"])
                    )
                    expected = {"matches": match}
                    outcomes[(operation, match)] += 1
                elif operation == "connection.init":
                    assert owner not in connections, "Repeated owner initialization"
                    connections[owner] = {"snapshot": inputs["snapshot"], "generation": inputs["generation"]}
                    expected = {"snapshot": projected(inputs["snapshot"]), "generation": inputs["generation"]}
                elif operation == "connection.transition":
                    state = connections[owner]
                    previous, current = state["snapshot"], inputs["next_native_snapshot"]
                    assert route(previous) == route(inputs["previous_native_snapshot"]), (
                        "Native route diverged from owner"
                    )
                    assert previous["is_connected"] == inputs["previous_native_snapshot"]["is_connected"]
                    changed = route(previous) != route(current)
                    status = previous["is_connected"] != current["is_connected"]
                    old_generation = state["generation"]
                    generation = old_generation
                    if changed or status:
                        generation = current["transport_generation"]
                        if generation is None:
                            generation = (old_generation + 1) % (1 << 64)
                    expected = {
                        "route_changed": changed,
                        "status_changed": status,
                        "invalidates_scope": changed or status,
                        "clear_pending": changed or not current["is_connected"],
                        "became_available": current["is_connected"] and (not previous["is_connected"] or changed),
                        "previous_generation": old_generation,
                        "current_generation": generation,
                    }
                    state["generation"] = generation
                elif operation == "connection.publish":
                    state = connections[owner]
                    state["snapshot"] = inputs["snapshot"]
                    expected = {"snapshot": projected(state["snapshot"]), "generation": state["generation"]}
                elif operation.startswith("index."):
                    if operation == "index.init":
                        assert owner not in indexes, "Repeated index owner initialization"
                        indexes[owner] = {"ids": [], "scopes": {}}
                    state = indexes[owner]
                    identifiers, scopes = state["ids"], state["scopes"]
                    removed = []
                    if operation == "index.upsert":
                        identity = inputs["id"]
                        if key(identity) not in scopes:
                            identifiers.append(identity)
                        scopes[key(identity)] = inputs["scope"]
                    elif operation == "index.remove":
                        identity = inputs["id"]
                        if key(identity) in scopes:
                            removed = [identity]
                            identifiers.remove(identity)
                            del scopes[key(identity)]
                    elif operation == "index.removeFirst":
                        assert 0 <= inputs["amount"] <= len(identifiers), "Original native removal bounds violated"
                        removed = identifiers[: inputs["amount"]]
                        del identifiers[: inputs["amount"]]
                        for identity in removed:
                            del scopes[key(identity)]
                    elif operation == "index.removeAll":
                        removed = identifiers[:]
                        identifiers.clear()
                        scopes.clear()
                    elif operation != "index.init":
                        raise AssertionError("Unknown index operation: " + operation)
                    expected = {
                        "ids": identifiers[:],
                        "scopes": [scopes[key(i)] for i in identifiers],
                        "count": len(scopes),
                        "removed": removed,
                    }
                else:
                    raise AssertionError("Unknown actual runtime operation: " + operation)
                assert expected == actual, (path, line_number, operation, expected, actual)
                if "native" in row:
                    assert expected == row["native"], (path, line_number, "native differs from independent old leaf")
                comparisons += 1
    assert comparisons > 0, "No actual core operations were recorded"
    return {
        "oracle_revision": "36692f1422b0c3952f9048847a0bafd65421bc72",
        "files": len(files),
        "catalogue_records": catalogues_total,
        "actual_operations": comparisons,
        "operation_counts": dict(counts),
        "scope_outcomes": [
            {"operation": op, "matches": match, "count": count} for (op, match), count in outcomes.items()
        ],
        "comparison_location": "Tests-only legacy replay against actual Kit results; pre-cut dual rows remain readable",
        "independent_legacy_replay_differences": 0,
        "expected_negative_children_excluded": "expected-negative/*; parent test requires abnormal termination",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    summary = verify(args.directory)
    args.output.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
