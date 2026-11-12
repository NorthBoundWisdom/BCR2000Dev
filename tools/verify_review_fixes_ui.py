#!/usr/bin/env python3
"""Native review-fix acceptance hook; run with mcp_integration.py --configuration-write."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from mcp_smoke import Client
from native_ui import NativeUI

pid = int(os.environ["BCR_INTEGRATION_APP_PID"])
ui = NativeUI(pid)
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])


def gui(body):
    return ui.run(body.replace("window 1", "mainWindow"))


def debug_failure(kind, value, trace):
    try:
        (directory / "ui-tree.txt").write_text(gui("return entire contents of window 1"))
        (directory / "windows.txt").write_text(gui("return properties of every window"))
    except RuntimeError:
        pass
    sys.__excepthook__(kind, value, trace)


sys.excepthook = debug_failure


def wait_for(check, message):
    until = time.monotonic() + 5
    while time.monotonic() < until:
        try:
            if check():
                return
        except RuntimeError:
            pass
        time.sleep(0.1)
    raise RuntimeError(message)


def press_help(help_text, area=1):
    return gui(f'''repeat with buttonIndex from 1 to count of buttons of scroll area {area} of group 1 of window 1
if help of button buttonIndex of scroll area {area} of group 1 of window 1 is {json.dumps(help_text, ensure_ascii=False)} then
perform action "AXPress" of button buttonIndex of scroll area {area} of group 1 of window 1
return "pressed"
end if
end repeat
error "button help not found"''')


def rejected(tool, arguments):
    try:
        client.call(tool, arguments)
    except RuntimeError:
        return
    raise RuntimeError("protected request unexpectedly succeeded: " + tool)


gui("set frontmost to true\nset position of window 1 to {80, 80}\nset size of window 1 to {1200, 760}")
original = client.parameter_definition("arm.enabled")
for changes in ({"agentWritable": True}, {"minimum": -1, "maximum": 0}, {"defaultValue": 1}):
    attack = dict(original, **changes)
    rejected("update_parameter", {"definition": attack})
    if client.parameter_definition("arm.enabled") != original:
        raise RuntimeError("rejected definition changed runtime state")
rejected("set_parameter", {"id": "arm.enabled", "value": 1})
client.call("set_parameter", {"id": "arm.j1", "value": 90})
reset = client.call("reset_group", {"group": "机械臂"})
if [entry["id"] for entry in reset["skipped"]] != ["arm.enabled"] or len(reset["results"]) != 8:
    raise RuntimeError("group reset skip report incorrect")
if client.call("get_parameter", {"id": "arm.j1"})["value"] != 0:
    raise RuntimeError("group reset did not reset writable joints")
print("Native MCP denied writable/range/default enable attacks and reset writable joints with an explicit skip report.")

# Exercise the real Canvas and readouts after configuring huge but finite values.
for identifier in ["arm.j1", "arm.j2", "arm.j3", "arm.j4", "arm.j5", "arm.j6", "arm.gripper", "arm.speed"]:
    definition = client.parameter_definition(identifier)
    definition.update(minimum=-1e300, maximum=1e300, defaultValue=0)
    client.call("update_parameter", {"definition": definition})
    client.call("set_parameter", {"id": identifier, "value": 1e300})
gui("set value of scroll bar 1 of scroll area 1 of group 1 of window 1 to 1.0")
# The arm preview is a specialist panel: enable it from the panel menu, which also selects it.
gui('perform action "AXPress" of menu button 1 of scroll area 1 of group 1 of window 1')
time.sleep(0.4)
gui('click menu item "机械臂预览" of menu 1 of menu button 1 of scroll area 1 of group 1 of window 1')
time.sleep(0.4)
tree = gui("return entire contents of window 1")
if "侧视" not in tree and "俯视" not in tree and "已使能" not in tree and "未使能" not in tree:
    raise RuntimeError("arm preview was not rendered")
if client.call("get_parameter", {"id": "arm.j1"})["value"] != 1e300:
    raise RuntimeError("large-value preview lost target data")
ui.capture(directory / "large-angle-preview.png", width=1200)
print("Native arm preview rendered huge finite joint/gripper/speed values without crashing; MCP remained responsive.")
