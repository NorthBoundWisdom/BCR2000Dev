#!/usr/bin/env python3
"""Verify Chinese stored builtin names in English native views without rewriting storage on display.

Run: python3 tools/mcp_integration.py --language en --configuration-write --script tools/verify_builtin_names_ui.py
"""

import json
import os
from pathlib import Path

from mcp_smoke import Client
from native_ui import NativeUI

ui = NativeUI(os.environ["BCR_INTEGRATION_APP_PID"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])
chinese = [
    "J1 底座旋转",
    "J2 肩部",
    "J3 肘部",
    "J4 腕部俯仰",
    "J5 腕部旋转",
    "J6 末端旋转",
    "夹爪开合",
    "运动速度",
]
identifiers = [*(f"arm.j{index}" for index in range(1, 7)), "arm.gripper", "arm.speed"]


def press_help(text, container):
    ui.run(f'''repeat with itemIndex from 1 to count of buttons of {container}
set candidate to button itemIndex of {container}
if help of candidate is {json.dumps(text)} then
perform action "AXPress" of candidate
return "pressed"
end if
end repeat
error "Requested help button missing"''')


def tree(scope="mainWindow"):
    return ui.run(f"return entire contents of {scope}")


def translated(scope):
    value = tree(scope)
    assert "J1 Base Rotation" in value, value[-3000:]
    assert all(name not in value for name in chinese), value[-3000:]
    return True


ui.run("set frontmost to true\nset position of mainWindow to {40, 40}\nset size of mainWindow to {1680, 900}")
for identifier, name in zip(identifiers, chinese, strict=True):
    definition = client.parameter_definition(identifier)
    definition.update(name=name, group="机械臂")
    client.call("update_parameter", {"definition": definition})

configuration = directory / "surface-configuration.json"
before = configuration.read_bytes()
ui.wait(lambda: translated("mainWindow"), "Workspace did not display builtin names in English")
press_help("Configure OSC output, soft limits, speed, and LED source", "group 1 of mainWindow")
ui.wait(lambda: ui.run("return count of sheets of mainWindow") == "1", "Output sheet missing")
translated("sheet 1 of mainWindow")
ui.run('perform action "AXPress" of button 1 of group 1 of sheet 1 of mainWindow')
ui.run("set value of scroll bar 1 of scroll area 2 of group 1 of mainWindow to 1.0")
# The protected enable parameter retains its original group. Pick the Chinese stored group (first in parameter order),
# whose translated label intentionally matches the original English group; tags remain distinct.
if ui.offscreen:
    ui.press("bulk.group")
    ui.wait(lambda: ui.exists("bulk.group.option.0"), "Parameter group options missing")
    ui.press("bulk.group.option.0")
else:
    ui.run("click pop up button 6 of scroll area 2 of group 1 of mainWindow")
    ui.run("click first menu item of menu 1 of pop up button 6 of scroll area 2 of group 1 of mainWindow")
press_help("Preview sequential row assignments, then confirm to apply", "scroll area 2 of group 1 of mainWindow")
ui.wait(lambda: ui.run("return count of sheets of mainWindow") == "1", "Bulk preview missing")
translated("sheet 1 of mainWindow")
ui.run('perform action "AXPress" of button 1 of group 1 of sheet 1 of mainWindow')
assert configuration.read_bytes() == before, "Viewing localized text rewrote the saved configuration"
for identifier, name in zip(identifiers, chinese, strict=True):
    definition = client.parameter_definition(identifier)
    assert definition["name"] == name and definition["group"] == "机械臂"
print(
    "PASS English workspace, bulk preview and output settings with Chinese stored names; JSON and MCP names unchanged"
)
