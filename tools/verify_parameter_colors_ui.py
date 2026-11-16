#!/usr/bin/env python3
"""Select a software color tag and group highlight in the isolated Mock console."""

import json
import os
from pathlib import Path

from mcp_smoke import Client
from native_ui import NativeUI

ui = NativeUI(os.environ["BCR_INTEGRATION_APP_PID"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])
try:
    ui.run("set size of mainWindow to {1200, 760}")
    ui.press("parameter.color")
    ui.wait(lambda: ui.exists("parameter.color.purple"), "Color menu did not open")
    ui.press("parameter.color.purple")
    profile = directory / "surface-configuration.json"

    def saved_color():
        return next(p for p in json.loads(profile.read_text())["parameters"] if p["id"] == "arm.j1").get("color")

    ui.wait(lambda: profile.exists() and saved_color() == "purple", "Color was not persisted")
    info = client.call("get_parameter", {"id": "arm.j1"})
    assert "color" not in info, "Local colors changed the legacy MCP parameter shape"
    ui.press("parameters.highlight." + info["group"])
    ui.capture(directory / "parameter-colors.png", width=1200)
    print("PASS color menu, durable label, group highlight and unchanged legacy MCP parameter shape")
except Exception:
    (directory / "parameter-colors-ui-failure.txt").write_text(ui.run("return entire contents of every window"))
    raise
