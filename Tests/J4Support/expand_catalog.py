#!/usr/bin/env python3
"""Expand one exact diagnostic owner/ordinal; never authorize, normalize or read native state."""

from __future__ import annotations
import argparse
import json
import math
from pathlib import Path


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def finite_json_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("nonfinite numeric overflow")
    return value


def finite_json_int(text):
    value = int(text)
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        raise ValueError("nonfinite integer overflow")
    return value


def loads(data):
    return json.loads(
        data,
        parse_float=finite_json_float,
        parse_int=finite_json_int,
        object_pairs_hook=object_pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite")),
    )


def expand(directory, suffix, owner, ordinal):
    directory = Path(directory)
    catalog = {}
    for line in (directory / ("catalog-" + suffix)).open():
        row = loads(line)
        if set(row) != {"id", "kind", "value"} or row["id"] in catalog or row["kind"] not in ("literal", "composite"):
            raise ValueError("missing/duplicate/conflicting catalog entry")
        catalog[row["id"]] = (row["kind"], row["value"])

    def resolve(value, active=frozenset()):
        if isinstance(value, dict):
            if set(value) == {"$catalog"}:
                key = value["$catalog"]
                if key not in catalog or key in active:
                    raise ValueError("missing/cyclic catalog reference")
                kind, original = catalog[key]
                return original if kind == "literal" else resolve(original, active | {key})
            return {key: resolve(item, active) for key, item in value.items()}
        if isinstance(value, list):
            return [resolve(item, active) for item in value]
        return value

    state, cursor = {}, 0
    inputs = (directory / ("inputs-" + suffix)).open()
    outputs = (directory / ("candidate-catalog-" + suffix)).open()
    required_state = {
        "owner",
        "input_ordinal",
        "rate",
        "queued",
        "withheld",
        "desired",
        "accepted_cache",
        "awaiting_gate",
        "awaiting_receipt",
        "tokens",
        "last_refill",
        "retry_after",
        "persistent_alignment_differences",
    }
    for left, right in zip(inputs, outputs, strict=True):
        event, output = loads(left), loads(right)
        if (
            not isinstance(event, dict)
            or set(event) != {"schema_version", "owner", "ordinal", "operation", "arguments", "context"}
            or type(event["schema_version"]) is not int
            or event["schema_version"] != 1
        ):
            raise ValueError("unknown/incomplete canonical input schema")
        required_output = {
            "artifact",
            "owner",
            "ordinal",
            "state_delta",
            "proposals",
            "removed_keys",
            "replaced_keys",
            "deduplicated_keys",
            "gates",
            "receipts",
            "alignment_differences",
        }
        if (
            not isinstance(output, dict)
            or set(output) != required_output
            or output["artifact"] != "scheduler_candidate_catalog_output_v1"
        ):
            raise ValueError("unknown/incomplete catalog output schema")
        if event["owner"] != output["owner"] or event["ordinal"] != output["ordinal"]:
            raise ValueError("input/output association")
        if event["owner"] != owner:
            continue
        raw = event["ordinal"]
        if str(int(raw)) != raw or int(raw) != cursor + 1:
            raise ValueError("missing/reordered ordinal")
        cursor += 1
        for key, patch in output["state_delta"].items():
            if set(patch) == {"replace"}:
                state[key] = patch["replace"]
            elif set(patch) == {"append"} and isinstance(state.get(key), list):
                state[key] = state[key] + patch["append"]
            else:
                raise ValueError("invalid state delta")
        if set(state) != required_state or state["input_ordinal"] != raw or state["owner"] != owner:
            raise ValueError("incomplete state/cursor")
        if cursor == ordinal:
            result = {
                key: resolve(output[key])
                for key in (
                    "proposals",
                    "removed_keys",
                    "replaced_keys",
                    "deduplicated_keys",
                    "gates",
                    "receipts",
                    "alignment_differences",
                )
            }
            result.update(artifact="scheduler_candidate_output_v1", input=event, state=resolve(state))
            return result
    raise ValueError("requested ordinal absent")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--suffix", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--ordinal", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.ordinal < 1 or Path(args.suffix).name != args.suffix:
        raise ValueError("invalid selector")
    args.output.write_text(
        json.dumps(expand(args.directory, args.suffix, args.owner, args.ordinal), sort_keys=True, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
