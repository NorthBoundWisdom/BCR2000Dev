#!/usr/bin/env python3
"""Start and finish JSONL evidence in an isolated Mock app."""

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
    ui.press_description("MIDI 监视")
    ui.press("monitor.capture.start")
    client.call("set_parameter", {"id": "arm.j1", "value": 63})
    ui.press("monitor.capture.stop")

    def records():
        files = list((directory / "Captures").glob("*.jsonl"))
        return [] if not files else [json.loads(line) for line in files[0].read_text().splitlines()]

    ui.wait(lambda: records() and records()[-1].get("kind") == "capture-end", "Capture footer did not finish")
    rows = records()
    assert rows[0]["kind"] == "capture-start" and rows[0]["session"]["deviceSource"] == "mock"
    assert rows[-1]["eventCount"] == len(rows) - 2
    assert any(row.get("source") == "agent" for row in rows[1:-1])
    assert all("monotonicTimestamp" in row for row in rows)
    ui.run("set value of scroll bar 1 of scroll area 1 of group 1 of mainWindow to 1.0")
    ui.capture(directory / "monitor-capture.png", width=1200)
    print("PASS monitor recording start/stop, header facts, events and durable footer")
except Exception:
    (directory / "monitor-capture-ui-failure.txt").write_text(ui.run("return entire contents of every window"))
    raise
