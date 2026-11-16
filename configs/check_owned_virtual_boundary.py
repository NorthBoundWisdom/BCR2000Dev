#!/usr/bin/env python3
"""Keep the owned-only MIDI implementation closed to native factories and discovery APIs."""

from __future__ import annotations
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ("OwnedVirtualMIDI.swift", "OwnedVirtualRehearsalDevice.swift", "SystemOwnedVirtualMIDIAPI.swift")
ALLOWED_MIDI_CALLS = frozenset(
    {
        "MIDIClientCreateWithBlock",
        "MIDISourceCreateWithProtocol",
        "MIDIDestinationCreateWithProtocol",
        "MIDIInputPortCreateWithProtocol",
        "MIDIOutputPortCreate",
        "MIDIObjectGetIntegerProperty",
        "MIDIPortConnectSource",
        "MIDIPortDisconnectSource",
        "MIDISendEventList",
        "MIDIReceivedEventList",
        "MIDIPortDispose",
        "MIDIEndpointDispose",
        "MIDIClientDispose",
        "MIDIEventList",
        "MIDIEventListInit",
        "MIDIEventListAdd",
        "MIDIEventPacketNext",
        "MIDIConnectionSnapshot",
    }
)


def code(source):
    return re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"', " ", source)


def inspect(source):
    text = code(source)
    failures = []
    if re.search(r"\bCoreMIDIService\b", text):
        failures.append("ordinary native factory is forbidden in the owned-only backend")
    if re.search(r"\b(?:MIDIGet\w*|MIDIEntityGet\w*|MIDIDeviceGet\w*|MIDIObjectFindByUniqueID)\b", text):
        failures.append("enumeration/lookup symbol is forbidden, including function aliases")
    for name in re.findall(r"\b(MIDI[A-Za-z0-9_]+)\s*\(", text):
        if name not in ALLOWED_MIDI_CALLS:
            failures.append("unapproved MIDI call: " + name)
    return failures


def factory_branch(source):
    start = source.index("if options.ownedVirtualRehearsal {", source.index("let hardware: any SurfaceDevice"))
    start = source.index("{", start)
    text = code(source[start:])
    level = 0
    for index, character in enumerate(text):
        if character == "{":
            level += 1
        elif character == "}":
            level -= 1
            if level == 0:
                return text[: index + 1]
    raise ValueError("Unclosed owned-only factory branch")


def check(root=ROOT):
    errors = []
    for name in FILES:
        path = root / "Sources/BCRCoreMIDIDriver" / name
        if not path.is_file():
            errors.append("missing owned-only source: " + name)
        else:
            errors.extend(name + ": " + error for error in inspect(path.read_text()))
    service = (root / "Sources/BCRProviderService/ProviderService.swift").read_text()
    errors.extend("owned factory: " + error for error in inspect(factory_branch(service)))
    return errors


def main():
    errors = check()
    if errors:
        raise SystemExit("\n".join(errors))
    print("Verified owned-only syscall allowlist and no ordinary factory in rehearsal branch")


if __name__ == "__main__":
    main()
