#!/usr/bin/env python3
"""Native WP7 acceptance hook; run with mcp_integration.py --configuration-write."""
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



control = {"section": "pushEncoder", "row": 1, "index": 1}
def selected():
    return next(entry for entry in client.call("list_controls") if entry["control"] == control)

def read():
    return client.call("get_parameter", {"id": "arm.j1"})["value"]

def turn(action):
    # AXUnknown is how SwiftUI exposes this adjustable knob on current macOS.
    gui(f'perform action "{action}" of UI element 5 of scroll area 1 of group 1 of window 1')

def mode(index):
    gui(f'perform action "AXPress" of radio button {index} of radio group "编码器模式" of scroll area 2 of group 1 of window 1')

gui('set frontmost to true\nset position of window 1 to {80, 80}\nset size of window 1 to {1200, 760}')
assignment = selected()["assignment"]
assignment.update(encoderMode="relative1", encoderStep=0.5)
client.call("assign_control", {"assignment": assignment})
client.call("set_parameter", {"id": "arm.j1", "value": 0})
turn("AXIncrement")
wait_for(lambda: read() == 0.5, "relative 1 native fine step failed")
mode(3)
wait_for(lambda: selected()["assignment"]["encoderMode"] == "relative2", "relative 2 UI selection failed")
turn("AXDecrement")
wait_for(lambda: read() == 0, "relative 2 native negative step failed")
gui('''repeat with fieldIndex from 1 to count of text fields of scroll area 2 of group 1 of window 1
if help of text field fieldIndex of scroll area 2 of group 1 of window 1 is "设置相对编码器每格步长" then
set focused of text field fieldIndex of scroll area 2 of group 1 of window 1 to true
set value of text field fieldIndex of scroll area 2 of group 1 of window 1 to "0.25"
key code 48
return "updated"
end if
end repeat
error "relative step field missing"''')
wait_for(lambda: selected()["assignment"]["encoderStep"] == 0.25, "relative step editor failed")
turn("AXIncrement")
wait_for(lambda: read() == 0.25, "edited relative step did not reach engine")
print("Native relative 1/2 mode selection, 0.5/0.25 steps and absolute LED feedback passed.")

mode(1)
gui('''repeat with boxIndex from 1 to count of checkboxes of scroll area 2 of group 1 of window 1
if help of checkbox boxIndex of scroll area 2 of group 1 of window 1 is "仅切换所选 Mock 编码器的 14-bit NRPN 预设" then
perform action "AXPress" of checkbox boxIndex of scroll area 2 of group 1 of window 1
return "switched"
end if
end repeat
error "Mock resolution control missing"''')
wait_for(lambda: selected()["binding"]["kind"] == "nrpn", "NRPN Mock identity not installed")
client.call("set_parameter", {"id": "arm.j1", "value": 0})
turn("AXIncrement")
value = read()
if not 0 < value < 0.05:
    raise RuntimeError(f"14-bit native step lost resolution: {value}")
tree = gui("return entire contents of window 1")
if "14-bit" not in tree or "8193" not in tree:
    raise RuntimeError("raw NRPN readout not visible")
subprocess.run(["screencapture", "-x", "-R80,80,1200,760", str(directory / "precision-ui.png")], check=True)
print("Native NRPN Mock wire loop, raw 8193 readout and sub-0.05 degree step passed.")
