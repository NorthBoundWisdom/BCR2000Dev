#!/usr/bin/env python3
"""Exercise local value undo/redo in the isolated Mock app, including MCP-origin changes."""

import os
from pathlib import Path

from mcp_smoke import Client
from native_ui import NativeUI

ui = NativeUI(os.environ["BCR_INTEGRATION_APP_PID"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])

try:
    ui.run("set size of mainWindow to {1200, 760}")
    before = client.call("get_parameter", {"id": "arm.j1"})["value"]
    changed = 91 if before != 91 else 37
    client.call("set_parameter", {"id": "arm.j1", "value": changed})
    ui.wait(lambda: ui.exists("parameters.undo"), "Parameter undo button missing")
    ui.press("parameters.undo")
    ui.wait(lambda: client.call("get_parameter", {"id": "arm.j1"})["value"] == before, "Undo did not restore value")
    ui.press("parameters.redo")
    ui.wait(lambda: client.call("get_parameter", {"id": "arm.j1"})["value"] == changed, "Redo did not restore value")
    menu = ui.run("return entire contents of menu bar 1")
    assert "撤销数值变化" in menu and "重做数值变化" in menu, menu
    ui.run("set value of scroll bar 1 of scroll area 1 of group 1 of mainWindow to 1.0")
    ui.capture(directory / "parameter-history.png", width=1200)
    print("PASS parameter Undo/Redo buttons and Edit menu; MCP writes participate in local value history")
except Exception:
    (directory / "parameter-history-ui-failure.txt").write_text(ui.run("return entire contents of every window"))
    raise
