#!/usr/bin/env python3
"""Native MIDI endpoint settings acceptance hook; run with mcp_integration.py --configuration-write."""

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


gui("set frontmost to true\nset position of window 1 to {80, 80}\nset size of window 1 to {1200, 760}")
gui('''repeat with i from 1 to count of buttons of group 1 of window 1
if help of button i of group 1 of window 1 starts with "选择实体 MIDI 输入与输出端口" then
perform action "AXPress" of button i of group 1 of window 1
return "opened"
end if
end repeat
error "MIDI endpoint button missing"''')
# Settings pages live in the one Settings window, titled after the selected page.
PAGE = 'group 1 of group 1 of (first window whose name is "设备")'
wait_for(lambda: gui('return count of (windows whose name is "设备")') != "0", "MIDI settings page missing")
text = gui(f"return value of every static text of {PAGE}")
if "隔离测试未启用实体 MIDI" not in text:
    raise RuntimeError("isolated MIDI state is not visible")
gui(f'''repeat with i from 1 to count of buttons of {PAGE}
if help of button i of {PAGE} is "保存并重新连接所选 MIDI 输入与输出端口" then
if enabled of button i of {PAGE} then error "isolated test enabled physical MIDI"
return "disabled"
end if
end repeat
error "Apply endpoint button missing"''')
for label in ["输入端口", "输出端口"]:
    if gui(f'return value of pop up button "{label}" of {PAGE}') != "自动 · Port 1":
        raise RuntimeError("unexpected default endpoint selection")
if ui.offscreen and os.environ.get("BCR_WINDOWSERVER_PROBE") == "1":
    try:
        ui.capture_windowserver(directory / "endpoint-windowserver-probe.png", width=1200)
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print("WindowServer probe unavailable for transparent window:", error)
ui.capture(directory / "endpoint-settings.png", width=1200)
print("Native endpoint settings page, default input/output and isolated physical-MIDI lock passed.")
