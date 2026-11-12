#!/usr/bin/env python3
"""Native consent/alignment acceptance. Requires mcp_integration.py --connection-fixture."""

import json
import os
from pathlib import Path
import sys

from mcp_smoke import Client
from native_ui import NativeUI

if os.environ.get("BCR_CONNECTION_FIXTURE") != "1":
    raise RuntimeError("This script requires the explicit isolated connection fixture; never run against hardware")

ui = NativeUI(os.environ["BCR_INTEGRATION_APP_PID"])
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])


def state():
    value = json.loads((directory / "connection-fixture.json").read_text())
    assert value["fixture"] is True
    return value


def status():
    return client.call("get_status")


def open_preview():
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.exists("preset.menu.align"), "Alignment menu item missing")
    ui.press("preset.menu.align")
    ui.wait(lambda: ui.exists("preset.preview"), "Read-only alignment preview did not appear")
    assert state()["presetWrites"] == 0


def verify_button_function_confirmation():
    # Select an unassigned button, so selection itself cannot start an Agent or enable output.
    ui.run('''set area to scroll area 1 of group 1 of mainWindow
set helpTexts to get help of every button of area
repeat with itemIndex from 1 to count of helpTexts
try
if (item itemIndex of helpTexts as text) ends with "B2-2" then
perform action "AXPress" of button itemIndex of area
return "selected"
end if
end try
end repeat
error "Unassigned B2-2 button missing"''')
    ui.wait(lambda: ui.exists("hardware.buttonFunctions.change"), "Button function action missing")
    path = directory / "hardware-map.json"
    original = json.loads(path.read_text())
    ui.press("hardware.buttonFunctions.change")
    ui.wait(lambda: ui.exists("hardware.buttonFunctions.confirm"), "Button function confirmation missing")
    assert json.loads(path.read_text()) == original
    ui.run("set frontmost to true\nkey code 53")
    ui.wait(lambda: not ui.exists("hardware.buttonFunctions.confirm"), "Cancel did not dismiss confirmation")
    assert json.loads(path.read_text()) == original
    expected = json.loads(json.dumps(original))
    target = next(
        entry for entry in expected["entries"] if entry["control"] == {"section": "button", "row": 2, "index": 2}
    )
    assert target.pop("visualizationOnly") is True

    def confirm(expected_map, message):
        # A dismissing AX element can disappear before the press reply. Never click twice:
        # require the exact saved map and closed confirmation to resolve that ambiguous reply.
        press_error = None
        try:
            ui.press("hardware.buttonFunctions.confirm")
        except RuntimeError as error:
            press_error = error
        try:
            ui.wait(
                lambda: (
                    json.loads(path.read_text()) == expected_map and not ui.exists("hardware.buttonFunctions.confirm")
                ),
                message,
            )
        except RuntimeError:
            if press_error:
                raise RuntimeError(f"{message}; AX reply: {press_error}") from press_error
            raise
        if press_error:
            print("Confirmed the saved map and closed dialog after an unavailable AX reply", flush=True)

    ui.press("hardware.buttonFunctions.change")
    ui.wait(lambda: ui.enabled("hardware.buttonFunctions.confirm"), "Enable confirmation missing")
    confirm(expected, "Enable changed more than the selected flag")
    assert state()["presetWrites"] == 1
    ui.press("hardware.buttonFunctions.change")
    ui.wait(lambda: ui.enabled("hardware.buttonFunctions.confirm"), "Disable confirmation missing")
    confirm(original, "Disable did not restore the selected flag")
    assert state()["presetWrites"] == 1


def run():
    capture = os.environ.get("BCR_CAPTURE_README") == "1"
    size = "{1680, 900}" if capture else "{1200, 760}"
    images = Path(__file__).resolve().parent.parent / "docs/images"
    ui.run(f"set frontmost to true\nset position of mainWindow to {{40, 40}}\nset size of mainWindow to {size}")
    ui.wait(lambda: ui.exists("connection.dialog"), "Initial connection confirmation did not appear")
    assert state()["voiceWrites"] == state()["presetWrites"] == 0
    assert status()["hardwareConnection"]["confirmation"] == "pending"
    if capture:
        ui.capture(images / "connection-confirmation.png")
    ui.press("connection.decline")
    ui.wait(lambda: status()["hardwareConnection"]["confirmation"] == "declined", "Decline was not observable")
    assert status()["source"] == "mock" and state()["voiceWrites"] == 0
    client.call("set_device_source", {"source": "hardware"}, expect_error=True)
    ui.wait(lambda: ui.exists("connection.read"), "Read connection option did not reappear")
    ui.press("connection.read")
    ui.wait(lambda: status()["source"] == "hardware", "Read connection did not complete")
    assert status()["hardwareConnection"]["confirmation"] == "none"
    assert state()["voiceWrites"] == state()["presetWrites"] == 0
    for iteration in range(3):
        open_preview()
        if capture and iteration == 0:
            ui.capture(images / "preset-alignment.png")
        ui.press("preset.option.enableButtonFunctions")
        ui.press("preset.option.enableButtonFunctions")
        ui.press("preset.close")
        ui.wait(lambda: not ui.exists("preset.dialog"), "Preview did not close")
    assert len(list((directory / "Backups").glob("*.syx"))) == 1
    open_preview()
    ui.press("preset.write")
    ui.wait(lambda: ui.exists("preset.writing") or ui.exists("preset.finished"), "Write did not start or finish")
    ui.wait(lambda: ui.exists("preset.finished"), "Alignment write/readback did not finish")
    assert state()["presetWrites"] == 1 and not state()["matchesOriginal"]
    ui.press("preset.close")
    verify_button_function_confirmation()
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.exists("preset.menu.restore"), "Restore menu item missing")
    ui.press("preset.menu.restore")
    ui.wait(lambda: ui.exists("preset.restoring") or ui.exists("preset.finished"), "Restore did not start or finish")
    ui.wait(lambda: ui.exists("preset.finished"), "Restore did not finish")
    assert state()["presetWrites"] == 2 and state()["matchesOriginal"]
    assert not (directory / "preset-alignment-restore.json").exists()
    ui.press("preset.close")
    print(
        "PASS native connection decline/read, read-only preview/deduplication, options, write/readback and restore",
        flush=True,
    )


try:
    run()
except Exception:
    try:
        (directory / "connection-ui-tree.txt").write_text(ui.run("return entire contents of mainWindow"))
    except RuntimeError:
        pass
    raise
