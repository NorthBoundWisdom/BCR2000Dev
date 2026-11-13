#!/usr/bin/env python3
"""Switch language in one isolated native process and keep its parameter/configuration state."""

import json
import os
from pathlib import Path

from mcp_smoke import Client
from native_ui import NativeUI

ui = NativeUI(os.environ["BCR_INTEGRATION_APP_PID"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])


def main_tree():
    return ui.run("return entire contents of mainWindow")


def all_windows():
    return ui.run("return entire contents of every window")


try:
    ui.run("set size of mainWindow to {1200, 760}")
    definition = client.parameter_definition("arm.j1")
    definition["name"] = "自定义 Custom {0}"
    client.call("update_parameter", {"definition": definition})
    client.call("set_parameter", {"id": "arm.j1", "value": 37})
    config = directory / "surface-configuration.json"
    stored = config.read_bytes()
    source = client.call("get_status")["source"]
    ui.wait(lambda: "跟随触碰" in main_tree(), "Initial Chinese interface missing")
    ui.press("app.settings")
    ui.press_description("语言")
    ui.wait(lambda: ui.exists("app-language"), "Language settings missing")
    ui.press_description("English")
    ui.wait(lambda: "Follow Touch" in main_tree(), "Main window did not switch to English")
    ui.wait(
        lambda: "System menus, file panels and system dialog buttons switch after restarting" in all_windows(),
        "Open settings did not update",
    )
    ui.wait(lambda: "Settings…" in ui.run("return entire contents of menu bar 1"), "Settings command did not update")
    assert "Language" in ui.run("return name of every window"), "Settings window title did not update"
    ui.capture(directory / "language-english.png", width=1200)
    assert client.call("get_parameter", {"id": "arm.j1"})["value"] == 37
    assert config.read_bytes() == stored
    ui.press_description("简体中文")
    ui.wait(lambda: "跟随触碰" in main_tree(), "Main window did not switch back to Chinese")
    ui.wait(
        lambda: "系统菜单、文件面板和系统对话框按钮需重启应用后切换" in all_windows(),
        "Open settings did not switch back",
    )
    assert "语言" in ui.run("return name of every window"), "Settings window title did not switch back"
    ui.capture(directory / "language-chinese.png", width=1200)
    assert client.call("get_parameter", {"id": "arm.j1"})["value"] == 37
    assert client.call("get_status")["source"] == source
    assert client.parameter_definition("arm.j1")["name"] == definition["name"]
    assert config.read_bytes() == stored
    print("PASS live Chinese/English switch in the same process; values, user names and configuration preserved")
except Exception:
    (directory / "language-ui-failure.txt").write_text(all_windows())
    raise
