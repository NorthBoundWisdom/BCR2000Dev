#!/usr/bin/env python3
"""Prove first-frame/UI responsiveness before delayed MIDI readiness, then a confirmed P- 1.

BCR_FIXTURE_STARTUP_DELAY_MS=10000 BCR_FIXTURE_PRESET_NUMBER=1 BCR_FIXTURE_DUPLICATE_NAMES=1 \
python3 tools/mcp_integration.py --offscreen --connection-fixture --script tools/verify_startup_display_ui.py
"""

import json
import os
from pathlib import Path

from mcp_smoke import Client
from native_ui import NativeUI

if os.environ.get("BCR_CONNECTION_FIXTURE") != "1" or int(os.environ.get("BCR_FIXTURE_STARTUP_DELAY_MS", "0")) < 5000:
    raise RuntimeError("This scenario requires an explicitly delayed isolated MIDI fixture")
ui = NativeUI(os.environ["BCR_INTEGRATION_APP_PID"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])


def state():
    return json.loads((directory / "connection-fixture.json").read_text())


def led_value():
    try:
        return ui.value("surface.led")
    except RuntimeError as error:
        print(str(error), flush=True)
        return None


ui.wait(lambda: ui.exists("surface.led"), "First-frame surface did not appear")
assert state()["midiReady"] is False, "The window waited until MIDI initialization finished"
client.call("set_parameter", {"id": "arm.j1", "value": 37})
assert client.call("get_parameter", {"id": "arm.j1"})["value"] == 37
assert state()["voiceWrites"] == state()["presetWrites"] == 0
ui.capture(directory / "startup-before-midi.png", width=1200)
ui.wait(lambda: state()["midiReady"], "MIDI initialization did not complete", timeout=20)
ui.wait(lambda: ui.exists("connection.read"), "Read-only hardware connection choice missing")
ui.press("connection.read")


def settled_unknown():
    return state()["reads"] >= 1 and led_value() == "----"


ui.wait(settled_unknown, "Locked same-named preset did not settle as unknown")
# Connecting must not add two slow same-named slot dumps for a locked copy without proof.
assert state()["memoryReads"] == 0
ui.capture(directory / "unknown-before-confirmation.png", width=1200)
ui.press("surface.devicePresetMenu")
ui.wait(lambda: ui.enabled("preset.menu.number"), "Preset screen confirmation action missing")
ui.press("preset.menu.number")
ui.wait(lambda: ui.exists("preset.number.dialog"), "Preset number confirmation missing")
assert not ui.command("enabled-description", "确认与实机一致"), "No number may be selected by default"
ui.press("preset.number.option.1")
ui.capture(directory / "number-selected.png", width=1200)
ui.wait(lambda: ui.command("enabled-description", "确认与实机一致"), "Screen number was not selected")
ui.press_description("确认与实机一致")
ui.wait(lambda: not ui.exists("preset.number.dialog"), "Preset number confirmation did not close")
ui.wait(lambda: led_value() == "P- 1", "Confirmed preset 1 did not reach the segment display")
ui.capture(directory / "verified-preset-one.png", width=1200)
assert state()["memoryReads"] == 0
assert state()["voiceWrites"] == state()["presetWrites"] == 0
records = json.loads((directory / "preset-number-evidence.json").read_text())
assert records and all(record.get("uniquenessProven") is False for record in records)
print(
    "PASS surface/MCP usable before MIDI ready; locked same-named preset skips slot dumps; screen confirmation shows P- 1 and writes nothing"
)
