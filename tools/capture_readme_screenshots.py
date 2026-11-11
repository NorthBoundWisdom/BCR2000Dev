#!/usr/bin/env python3
"""Capture the README screenshots from the isolated Mock app.

Run with:
    python3 tools/mcp_integration.py --configuration-write --script tools/capture_readme_screenshots.py

Only the app's own window is captured (by window id), so other windows never leak into the
images and the app does not need to be frontmost. Requires Accessibility and Screen Recording
permission for the invoking terminal.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

from mcp_smoke import Client

pid = int(os.environ["BCR_INTEGRATION_APP_PID"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])
output = Path(__file__).resolve().parent.parent / "docs" / "images"
SIZE = (1680, 900)  # wide enough for the side-by-side workspace layout
WORKSPACE = "scroll area 1 of group 1 of window 1"


def gui(body):
    source = f"""tell application "System Events"
set targetProcess to first application process whose unix id is {pid}
tell targetProcess
set mainWindow to first window whose name starts with "BCRTest-"
{body.replace("window 1", "mainWindow")}
end tell
end tell"""
    result = subprocess.run(["osascript", "-e", source], capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def window_id():
    script = (
        'ObjC.import("CoreGraphics");'
        "var all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(0, 0)));"
        f"var own = all.filter(w => w.kCGWindowOwnerPID == {pid} && w.kCGWindowLayer == 0"
        f" && w.kCGWindowBounds.Width == {SIZE[0]});"
        "JSON.stringify(own.map(w => w.kCGWindowNumber))"
    )
    result = subprocess.run(
        ["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True, check=True, timeout=20
    )
    identifiers = json.loads(result.stdout)
    if len(identifiers) != 1:
        raise RuntimeError(f"expected exactly one main window, found {len(identifiers)}")
    return identifiers[0]


def capture(name):
    time.sleep(0.6)
    path = output / name
    subprocess.run(["screencapture", "-x", "-o", f"-l{window_id()}", str(path)], check=True)
    subprocess.run(["sips", "--resampleWidth", "1680", str(path)], check=True, capture_output=True)
    print("captured", path.relative_to(Path.cwd()))


def press_help(text):
    return gui(f'''repeat with i from 1 to count of buttons of {WORKSPACE}
if help of button i of {WORKSPACE} is {json.dumps(text, ensure_ascii=False)} then
perform action "AXPress" of button i of {WORKSPACE}
return "pressed"
end if
end repeat
error "button help not found"''')


def select_tab(title):
    gui(f'''repeat with i from 1 to count of radio buttons of radio group 1 of {WORKSPACE}
if description of radio button i of radio group 1 of {WORKSPACE} is {json.dumps(title, ensure_ascii=False)} then
perform action "AXPress" of radio button i of radio group 1 of {WORKSPACE}
return "selected"
end if
end repeat
error "workspace tab not found"''')


def enable_panel(title):
    gui(f'perform action "AXPress" of menu button 1 of {WORKSPACE}')
    time.sleep(0.4)
    gui(f"click menu item {json.dumps(title, ensure_ascii=False)} of menu 1 of menu button 1 of {WORKSPACE}")
    time.sleep(0.4)


output.mkdir(parents=True, exist_ok=True)
gui(f"set position of window 1 to {{20, 40}}\nset size of window 1 to {{{SIZE[0]}, {SIZE[1]}}}")
# Dismiss the isolated-test banner so the images match a normal launch.
gui('perform action "AXPress" of last button of group 1 of window 1')
if "隔离集成测试" in gui("return value of every static text of group 1 of window 1"):
    raise RuntimeError("isolated-test banner is still visible")
pose = {"arm.j1": 42, "arm.j2": 48, "arm.j3": -75, "arm.j4": -28, "arm.j5": 65, "arm.j6": -110}
pose.update({"arm.gripper": 72, "arm.speed": 35})
for identifier, value in pose.items():
    client.call("set_parameter", {"id": identifier, "value": value})

capture("console-overview.png")

# Stagger three Mock agents so the grid shows running, waiting-approval and queued states.
press_help("操作 B1-1")
time.sleep(2.9)
press_help("操作 B1-2")
time.sleep(1.2)
press_help("操作 B1-3")
select_tab("Agent")
capture("workspace-agents.png")

select_tab("MIDI 监视")
capture("workspace-midi-monitor.png")

enable_panel("机械臂预览")
# Enabling a panel selects it; its Canvas labels are not exposed, the enable readout is.
if "使能（B2-1 切换）" not in gui(f"return value of every static text of {WORKSPACE}"):
    raise RuntimeError("enabling the arm panel from the menu did not show it")
capture("workspace-arm-preview.png")
print("README screenshots updated.")
