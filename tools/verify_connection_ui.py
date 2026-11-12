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


def run():
    ui.run("set frontmost to true\nset position of mainWindow to {40, 40}\nset size of mainWindow to {1200, 760}")
    ui.wait(lambda: ui.exists("connection.dialog"), "Initial connection confirmation did not appear")
    assert state()["voiceWrites"] == state()["presetWrites"] == 0
    assert status()["hardwareConnection"]["confirmation"] == "pending"
    ui.press("connection.decline")
    ui.wait(lambda: status()["hardwareConnection"]["confirmation"] == "declined", "Decline was not observable")
    assert status()["source"] == "mock" and state()["voiceWrites"] == 0
    client.call("set_device_source", {"source": "hardware"}, expect_error=True)
    ui.wait(lambda: ui.exists("connection.read"), "Read connection option did not reappear")
    ui.press("connection.read")
    ui.wait(lambda: status()["source"] == "hardware", "Read connection did not complete")
    assert status()["hardwareConnection"]["confirmation"] == "none"
    assert state()["voiceWrites"] == state()["presetWrites"] == 0
    for _ in range(3):
        open_preview()
        ui.press("preset.option.enableButtonFunctions")
        ui.press("preset.option.enableButtonFunctions")
        ui.press("preset.close")
        ui.wait(lambda: not ui.exists("preset.dialog"), "Preview did not close")
    assert len(list((directory / "Backups").glob("*.syx"))) == 1
    open_preview()
    ui.press("preset.write")
    ui.wait(lambda: ui.exists("preset.writing"), "Write progress did not appear")
    ui.wait(lambda: ui.exists("preset.finished"), "Alignment write/readback did not finish")
    assert state()["presetWrites"] == 1 and not state()["matchesOriginal"]
    ui.press("preset.close")
    ui.press("surface.devicePresetMenu")
    ui.wait(lambda: ui.exists("preset.menu.restore"), "Restore menu item missing")
    ui.press("preset.menu.restore")
    ui.wait(lambda: ui.exists("preset.restoring"), "Restore progress did not appear")
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
