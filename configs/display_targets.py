#!/usr/bin/env python3
"""Generate/check offline display targets from the exact discovery and map files; never opens MIDI."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def targets(contract, mapping):
    discovery = contract["discovery"]
    profile = discovery["profile"]
    entries = {
        f"{e['control']['section']}.{e['control']['row']}.{e['control']['index']}": e for e in mapping["entries"]
    }
    rows = []
    excluded = []
    for control in profile["controls"]:
        kinds = control["feedback_kinds"]
        if not kinds:
            excluded.append(control["id"])
            continue
        entry = entries[control["id"]]
        if entry.get("visualizationOnly", False):
            raise ValueError("Visualization-only control must not declare display feedback")
        rows.append(
            {
                "id": control["id"],
                "kind": "ring" if control["input_kind"] == "absolute" else "button_led",
                "feedback_kinds": kinds,
                "range": control.get("feedback_range"),
                "style": entry.get("ringMode", "unknown") if "value" in kinds else "off=0/on=127/blink=static96",
                "style_evidence": "mock configuration"
                if discovery["source"] == "simulation"
                else "learned map expectation; actual preset not read",
                "eligibility": "declared by profile; simulation only"
                if discovery["source"] == "simulation"
                else "declared by profile; write policy + display permission required; not attended qualified",
                "visualization_only": False,
            }
        )
    return {
        "source": discovery["source"],
        "profile_id": profile["id"],
        "profile_version": profile["version"],
        "mapping_revision": discovery["expected"]["mapping_revision"],
        "targets": rows,
        "no_feedback_controls": excluded,
    }


def documents(directory):
    profiles = [
        targets(
            json.loads((directory / "control-contract.json").read_text()),
            json.loads((directory / "display-mock-map.json").read_text()),
        )
    ]
    if (directory / "hardware-control-contract.json").exists():
        profiles.append(
            targets(
                json.loads((directory / "hardware-control-contract.json").read_text()),
                json.loads((directory / "hardware-map.json").read_text()),
            )
        )
    value = {"schema_version": 1, "physical_qualification": False, "profiles": profiles}
    lines = [
        "# BCR display targets",
        "",
        "Generated from this package's exact discovery and map files. No device addresses are handwritten.",
        "Discovery already supplies stable IDs, feedback kinds and feedback ranges; it does not describe each ring style.",
        "This offline table supplies the style without changing frozen simulation discovery. Hardware styles are learned-map expectations, never a readback or attended qualification.",
        "Button blink is a static MIDI value 96 on BCR, not a flashing promise. Unknown ring mode remains unknown.",
        "Ring styles: 1dot shows one position dot; 12dot shows one or two adjacent dots. Both still light a dot at raw zero: zero is a resting position, not off.",
        "Only an explicitly declared indicator can be promised off by an off request; default hardware visualization-only buttons cannot serve as a freshness lamp.",
        "",
        "Run `python3 diagnostics/display_targets.py --directory . --check` from this package to verify both files.",
        "",
    ]
    for profile in profiles:
        lines += [
            f"## {profile['source']}: {profile['profile_id']} / {profile['profile_version']}",
            "",
            f"Mapping revision: `{profile['mapping_revision']}`. {len(profile['targets'])} display targets; {len(profile['no_feedback_controls'])} controls declare no feedback.",
            "",
            "| Stable ID | Kind | Feedback | Range | Configured style | Default eligibility |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        for row in profile["targets"]:
            r = row["range"]
            span = f"{r['minimum']}..{r['maximum']} step {r['step']}" if r else "off / on / blink"
            lines.append(
                f"| `{row['id']}` | {row['kind']} | {','.join(row['feedback_kinds'])} | {span} | {row['style']} | {row['eligibility']} |"
            )
        lines += [
            "",
            "Controls with no feedback (excluded): " + ", ".join(f"`{c}`" for c in profile["no_feedback_controls"]),
            "",
        ]
    return json.dumps(value, indent=2) + "\n", "\n".join(lines) + "\n"


def generate(directory, check=False):
    data, markdown = documents(directory)
    for name, content in (("display-targets.json", data), ("DISPLAY_TARGETS.md", markdown)):
        path = directory / name
        if check:
            if path.read_text() != content:
                raise ValueError(f"Generated display table differs: {name}")
        else:
            path.write_text(content)
    return json.loads(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = generate(args.directory, args.check)
    print(json.dumps({"passed": True, "targets": {p["source"]: len(p["targets"]) for p in result["profiles"]}}))


if __name__ == "__main__":
    main()
