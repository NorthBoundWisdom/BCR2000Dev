#!/usr/bin/env python3
"""Verify the permanently virtual driver and construction branch cannot name native IO factories."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def check(sources):
    launch = sources["Sources/BCRAgentConsole/GUIVirtualLaunch.swift"]
    construction = sources["Sources/BCRAgentConsole/ConsoleDeviceWork.swift"]
    closed = launch.split("final class PermanentMockOnlyMIDIService", 1)[1]
    closed = closed.split("@MainActor", 1)[0]
    branch = construction.split("switch runtimeMode {", 1)[1].split("case .normal:", 1)[0]
    for label, text in (("permanent virtual driver", closed), ("virtual construction branch", branch)):
        if re.search(
            r"CoreMIDIService|MIDIGet|MIDIClientCreate|MIDIInputPortCreate|MIDIOutputPortCreate|KeychainMCPCredentialStore|OutputTransportRouter",
            text,
        ):
            raise ValueError("Native IO reference in " + label)
    if "midi = context.midi" not in branch or "credentials = context.legacyCredential" not in branch:
        raise ValueError("Virtual construction must use the owned closed adapters")
    if "permitsHardwareSource: !runtimeMode.isVirtual" not in construction:
        raise ValueError("Virtual session lost its immutable source restriction")


def main():
    paths = ("Sources/BCRAgentConsole/GUIVirtualLaunch.swift", "Sources/BCRAgentConsole/ConsoleDeviceWork.swift")
    check({name: (ROOT / name).read_text() for name in paths})
    print("Verified virtual driver and constructor are closed to native IO factories")


if __name__ == "__main__":
    main()
