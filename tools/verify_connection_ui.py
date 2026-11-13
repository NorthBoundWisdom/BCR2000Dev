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
    assert ui.exists("preset.changes.summary")
    assert ui.exists("preset.changeGroup.newButton")
    ui.press("preset.changeGroup.newButton")
    ui.wait(lambda: ui.exists("preset.changeRow.newButton.0"), "Grouped changes did not expand")
    ui.press("preset.changeGroup.newButton")
    ui.wait(lambda: not ui.exists("preset.changeRow.newButton.0"), "Grouped changes did not collapse")
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
    if ui.offscreen:
        try:
            ui.press("hardware.buttonFunctions.cancel")
        except RuntimeError:
            # A closed AX element may lose its reply; the unchanged-map assertion below still applies.
            pass
    else:
        ui.run("set frontmost to true\nkey code 53")
    ui.wait_settled(
        lambda: not ui.exists("hardware.buttonFunctions.confirm") and ui.enabled("hardware.buttonFunctions.change"),
        "Cancel did not dismiss confirmation",
    )
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
            ui.wait_settled(
                lambda: (
                    json.loads(path.read_text()) == expected_map
                    and not ui.exists("hardware.buttonFunctions.confirm")
                    and ui.enabled("hardware.buttonFunctions.change")
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
    readme_capture = os.environ.get("BCR_CAPTURE_README") == "1"
    capture_directory = os.environ.get("BCR_UI_CAPTURE_DIRECTORY")
    capture = readme_capture or bool(capture_directory)
    width = 1680 if readme_capture else 1200
    size = "{1680, 900}" if readme_capture else "{1200, 760}"
    images = Path(capture_directory) if capture_directory else Path(__file__).resolve().parent.parent / "docs/images"
    # The MCP listener can start before the SwiftUI window is registered with accessibility.
    ui.wait(lambda: ui.exists("surface.led"), "Native surface window did not become ready")
    ui.run(f"set frontmost to true\nset position of mainWindow to {{40, 40}}\nset size of mainWindow to {size}")
    ui.wait(lambda: ui.exists("connection.dialog"), "Initial connection confirmation did not appear")
    assert state()["voiceWrites"] == state()["presetWrites"] == 0
    assert status()["hardwareConnection"]["confirmation"] == "pending"
    if capture:
        ui.capture(images / "connection-confirmation.png", width=width)
    ui.press("connection.decline")
    ui.wait(lambda: status()["hardwareConnection"]["confirmation"] == "declined", "Decline was not observable")
    assert status()["source"] == "mock" and state()["voiceWrites"] == 0
    client.call("set_device_source", {"source": "hardware"}, expect_error=True)
    ui.wait(lambda: ui.exists("connection.read"), "Read connection option did not reappear")
    # Return must choose the read-only option; writing and initialization have no default shortcut.
    if ui.offscreen:
        ui.press("connection.read")
    else:
        ui.run("set frontmost to true\nkey code 36")
    ui.wait(lambda: status()["source"] == "hardware", "Read connection did not complete")
    assert status()["hardwareConnection"]["confirmation"] == "none"
    assert state()["voiceWrites"] == state()["presetWrites"] == 0
    for iteration in range(3):
        open_preview()
        if iteration == 0:
            backups_before = {path.name: path.read_bytes() for path in (directory / "Backups").glob("*.syx")}
            ui.press("preset.backup.reveal")
            ui.run("set frontmost to true")
            assert backups_before == {path.name: path.read_bytes() for path in (directory / "Backups").glob("*.syx")}
            assert state()["presetWrites"] == 0
        if capture and iteration == 0:
            ui.capture(images / "preset-alignment.png", width=width)
        ui.press("preset.option.enableButtonFunctions")
        ui.press("preset.option.enableButtonFunctions")
        ui.press("preset.close")
        ui.wait(lambda: not ui.exists("preset.dialog"), "Preview did not close")
    assert len(list((directory / "Backups").glob("*.syx"))) == 1
    open_preview()
    ui.press("preset.write")
    # Probe immediately after intent dispatch: AX traversal can outlast the entire fixture write.
    client.call("set_device_source", {"source": "mock"}, expect_error=True)
    assert status()["source"] == "hardware"
    ui.wait(lambda: ui.exists("preset.writing") or ui.exists("preset.finished"), "Write did not start or finish")
    ui.wait(lambda: ui.exists("preset.finished"), "Alignment write/readback did not finish")
    assert state()["presetWrites"] == 1 and not state()["matchesOriginal"]
    ui.press("preset.close")
    ui.wait(lambda: not ui.exists("preset.dialog"), "Completed alignment did not close")
    ui.wait(lambda: ui.exists("surface.led"), "Segmented LED accessibility element missing")
    led_help = ui.help("surface.led")
    assert "on/oFF" in led_help, "LED display-rules help is missing"
    if capture_directory:
        ui.capture(images / "seven-segment-display.png", width=width)
    # Existing recovery controls and their disabled explanation must stay hidden in preview.
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.enabled("preset.menu.align"), "Alignment unavailable after a completed write")
    ui.press("preset.menu.align")
    ui.wait(lambda: ui.exists("preset.preview"), "Second preview missing")
    assert not ui.exists("preset.restore") and not ui.exists("preset.restore.unavailable")
    assert not ui.exists("preset.discard")
    ui.press("preset.close")
    # Cancelling a discard confirmation must preserve the exact recovery record.
    restore_path = directory / "preset-alignment-restore.json"
    saved_point = restore_path.read_bytes()
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.enabled("preset.menu.discard"), "Discard action missing")
    ui.press("preset.menu.discard")
    ui.wait(lambda: ui.exists("preset.discard.cancel"), "Discard confirmation missing")
    assert restore_path.read_bytes() == saved_point and state()["presetWrites"] == 1
    ui.press("preset.discard.cancel")
    ui.wait(lambda: not ui.exists("preset.discard.confirm"), "Discard cancellation did not close")
    assert restore_path.read_bytes() == saved_point
    verify_button_function_confirmation()
    # Leave a later host-map edit, then verify restore cannot silently discard it.
    ui.press("hardware.buttonFunctions.change")
    ui.wait(lambda: ui.enabled("hardware.buttonFunctions.confirm"), "Later mapping edit confirmation missing")
    ui.press("hardware.buttonFunctions.confirm")
    path = directory / "hardware-map.json"
    edited_map = json.loads(path.read_text())
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.exists("preset.menu.restore"), "Restore menu item missing")
    ui.press("preset.menu.restore")
    ui.wait(lambda: ui.exists("preset.restore.learningWarning"), "Later learning replacement warning missing")
    client.call("set_device_source", {"source": "mock"}, expect_error=True)
    assert status()["source"] == "hardware"
    assert state()["presetWrites"] == 1 and json.loads(path.read_text()) == edited_map
    if capture_directory:
        ui.capture(images / "restore-learning-warning.png", width=width)
    ui.press("preset.restore.cancel")
    ui.wait(lambda: not ui.exists("preset.restore.confirm"), "Cancel did not dismiss restore confirmation")
    assert state()["presetWrites"] == 1 and json.loads(path.read_text()) == edited_map
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.enabled("preset.menu.restore"), "Restore did not become available after cancel")
    ui.press("preset.menu.restore")
    ui.wait(lambda: ui.exists("preset.restore.confirm"), "Restore replacement confirmation missing")
    ui.press("preset.restore.confirm")
    client.call("set_device_source", {"source": "mock"}, expect_error=True)
    assert status()["source"] == "hardware"
    ui.wait(lambda: ui.exists("preset.restoring") or ui.exists("preset.finished"), "Restore did not start or finish")
    ui.wait(lambda: ui.exists("preset.finished"), "Restore did not finish")
    assert state()["presetWrites"] == 2 and state()["matchesOriginal"]
    assert not (directory / "preset-alignment-restore.json").exists()
    ui.press("preset.close")
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.enabled("preset.menu.backups"), "Backup folder action missing")
    ui.press("preset.menu.backups")
    ui.run("set frontmost to true")
    assert state()["presetWrites"] == 2 and state()["matchesOriginal"]
    # Confirming discard removes only the newest recovery record, keeping preset/map bytes.
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.enabled("preset.menu.align"), "Alignment unavailable after restore")
    ui.press("preset.menu.align")
    ui.wait(lambda: ui.exists("preset.preview"), "Final preview missing")
    ui.press("preset.write")
    ui.wait(lambda: ui.exists("preset.finished"), "Final alignment did not finish")
    ui.press("preset.close")
    before_discard = state()
    saved_map = path.read_bytes()
    backups = {file.name: file.read_bytes() for file in (directory / "Backups").glob("*.syx")}
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.enabled("preset.menu.discard"), "Final discard action missing")
    ui.press("preset.menu.discard")
    ui.wait(lambda: ui.exists("preset.discard.confirm"), "Discard confirmation action missing")
    ui.press("preset.discard.confirm")
    ui.wait(lambda: not restore_path.exists(), "Confirmed discard did not remove the recovery record")
    assert path.read_bytes() == saved_map and state() == before_discard
    assert backups == {file.name: file.read_bytes() for file in (directory / "Backups").glob("*.syx")}
    print(
        "PASS native connection decline/read, preview, write/readback, restore and discard confirmation/cancel",
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
