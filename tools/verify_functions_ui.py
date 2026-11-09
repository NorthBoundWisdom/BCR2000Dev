#!/usr/bin/env python3
"""Native WP5 acceptance hook; run with mcp_integration.py --configuration-write."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from mcp_smoke import Client

pid = int(os.environ["BCR_INTEGRATION_APP_PID"])
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])


def gui(body):
    source = f'''tell application "System Events"
set targetProcess to first application process whose unix id is {pid}
tell targetProcess
set mainWindow to first window whose name starts with "BCRTest-"
{body.replace("window 1", "mainWindow")}
end tell
end tell'''
    result = subprocess.run(["osascript", "-e", source], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


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


def assign(index, kind, fields):
    client.call("assign_control", {"assignment": {
        "control": {"section": "userButton", "row": 1, "index": index},
        "target": {kind: fields}, "buttonBehavior": "toggle", "inverted": False,
    }})


gui('set frontmost to true\nset position of window 1 to {80, 80}\nset size of window 1 to {1200, 760}')
info = client.call("get_parameter", {"id": "arm.j1"})
definition = {key: value for key, value in info.items() if key not in {"value", "writable", "controls"}}
definition["step"] = 0.5
client.call("update_parameter", {"definition": definition})
snapped = client.call("set_parameter", {"id": "arm.j1", "value": 90.26})
if snapped["value"] != 90.5 or not snapped["clamped"]:
    raise RuntimeError("MCP step quantization failed")
assign(1, "stepParameter", {"id": "arm.j1", "step": 0.5, "wraps": False})
press_help("操作 U1")
if client.call("get_parameter", {"id": "arm.j1"})["value"] != 91:
    raise RuntimeError("native step button did not advance by configured step")
assign(2, "setParameter", {"id": "arm.j1", "value": 45})
press_help("操作 U2")
if client.call("get_parameter", {"id": "arm.j1"})["value"] != 45:
    raise RuntimeError("native preset button did not set parameter")
assign(3, "cycleParameter", {"id": "arm.j1", "values": [-90, 0, 90]})
press_help("操作 U3")
if client.call("get_parameter", {"id": "arm.j1"})["value"] != -90:
    raise RuntimeError("native cycle did not select first unlisted preset")
time.sleep(0.3)
press_help("操作 U3")
if client.call("get_parameter", {"id": "arm.j1"})["value"] != 0:
    raise RuntimeError("native cycle did not advance")
print("Native step/preset/cycle controls and MCP step quantization passed.")

client.call("set_parameter", {"id": "arm.j2", "value": 44.5})
gui("set value of scroll bar 1 of scroll area 2 of group 1 of window 1 to 1.0")
press_help("预览整行与参数组的顺序绑定，确认后应用", area=2)
wait_for(lambda: "确认批量分配" in gui("return entire contents of window 1"), "bulk preview not shown")
gui('''repeat with buttonIndex from 1 to count of buttons of group 1 of sheet 1 of window 1
if help of button buttonIndex of group 1 of sheet 1 of window 1 is "确认应用预览中的批量分配" then
perform action "AXPress" of button buttonIndex of group 1 of sheet 1 of window 1
return "confirmed"
end if
end repeat
error "bulk confirmation missing"''')


def first_row_assigned():
    controls = client.call("list_controls")
    row = [entry for entry in controls if entry["control"]["section"] == "encoder" and entry["control"]["row"] == 1]
    return len(row) == 8 and row[0]["assignment"]["target"] == {"parameter": {"_0": "arm.j1"}} \
        and row[7]["assignment"]["target"] == {"parameter": {"_0": "arm.speed"}}


wait_for(first_row_assigned, "confirmed bulk assignment not applied")
if client.call("get_parameter", {"id": "arm.j2"})["value"] != 44.5:
    raise RuntimeError("bulk assignment reset live parameter values")
print("Native bulk preview/confirmation assigned E1 in order and preserved current parameter values.")
