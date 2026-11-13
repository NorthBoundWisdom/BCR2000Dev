#!/usr/bin/env python3
"""Native WP4 acceptance hook for tools/mcp_integration.py; never uses production files."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from mcp_smoke import Client
from native_ui import NativeUI

pid = int(os.environ["BCR_INTEGRATION_APP_PID"])
ui = NativeUI(pid)
if ui.offscreen:
    raise RuntimeError("Configuration acceptance requires foreground: product file panels explicitly activate the App")
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])


def quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def gui(body):
    return ui.run(body.replace("window 1", "mainWindow"))


def debug_failure(kind, value, trace):
    try:
        (directory / "ui-tree.txt").write_text(gui("return entire contents of window 1"))
        (directory / "windows.txt").write_text(gui("return properties of every window"))
        (directory / "button-properties.txt").write_text(
            gui("return properties of every button of scroll area 2 of group 1 of window 1")
        )
        (directory / "tree-shape.txt").write_text(
            gui("set entries to entire contents of window 1\nreturn {count of entries, class of item 1 of entries}")
        )
    except RuntimeError:
        pass
    sys.__excepthook__(kind, value, trace)


sys.excepthook = debug_failure


def wait_for(predicate, description, timeout=5):
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except RuntimeError as exc:
            last_error = str(exc)
        time.sleep(0.1)
    try:
        (directory / "ui-tree.txt").write_text(gui("return entire contents of window 1"))
        (directory / "windows.txt").write_text(gui("return properties of every window"))
    except RuntimeError:
        pass
    raise RuntimeError(description + (": " + last_error if last_error else ""))


def click_identifier(identifier):
    if identifier.startswith("configuration."):
        gui("set value of scroll bar 1 of scroll area 1 of group 1 of window 1 to 1.0")
        time.sleep(0.15)
    # System Events can omit SwiftUI identifiers on some macOS versions; the same
    # semantic control also has a public, localized help attribute.
    help_text = {
        "parameter.adoptExternal": "采用外部参数定义，放弃当前草稿",
        "configuration.import": "导入参数与功能分配，确认后替换当前配置",
        "configuration.export": "导出参数与功能分配，不包含实体映射",
    }[identifier]
    gui(f'''repeat with areaIndex from 1 to 2
set candidates to buttons of scroll area areaIndex of group 1 of window 1
repeat with buttonIndex from 1 to count of candidates
set candidateHelp to help of button buttonIndex of scroll area areaIndex of group 1 of window 1
if candidateHelp is {quote(help_text)} then
perform action "AXPress" of button buttonIndex of scroll area areaIndex of group 1 of window 1
return "pressed"
end if
end repeat
end repeat
error "semantic button help not found"''')


def go_to_path(path):
    def open_folder_sheet():
        if gui("return count of sheets of sheet 1 of window 1") != "0":
            return True
        gui('set frontmost to true\nkeystroke "g" using {command down, shift down}')
        return False

    wait_for(open_folder_sheet, "Go to Folder did not appear")
    gui(f"set value of text field 1 of sheet 1 of sheet 1 of window 1 to {quote(path)}")
    # Path completion is asynchronous. Confirm only while the Go to Folder sheet exists.
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if gui("return count of sheets of sheet 1 of window 1") == "0":
            return
        gui("key code 36")
        time.sleep(0.2)
    raise RuntimeError("Go to Folder did not accept the path")


def select_path(path, confirm):
    wait_for(lambda: gui("return count of sheets of window 1") != "0", "file panel did not appear")
    go_to_path(path)
    gui(f"click button {quote(confirm)} of splitter group 1 of sheet 1 of window 1")


# The inspector's TextFields expose their label as the accessibility description; on the current
# macOS their AppleScript name is empty, so look them up by description rather than by name.
gui("set frontmost to true\nset position of window 1 to {80, 80}\nset size of window 1 to {1200, 760}")
binding_before = [entry["binding"] for entry in client.call("list_controls")]
original = client.call("get_parameter", {"id": "arm.j1"})
definition = client.parameter_definition("arm.j1")
definition["name"] = "External J1"
client.call("update_parameter", {"definition": definition})
wait_for(
    lambda: (
        gui('return value of (first text field of scroll area 2 of group 1 of window 1 whose description is "名称")')
        == "External J1"
    ),
    "pristine parameter draft did not refresh",
)
gui("""set frontmost to true
set focused of (first text field of scroll area 2 of group 1 of window 1 whose description is "名称") to true
set value of (first text field of scroll area 2 of group 1 of window 1 whose description is "名称") to "LocalDraft"
key code 48""")
time.sleep(0.1)
definition["name"] = "Concurrent J1"
client.call("update_parameter", {"definition": definition})
wait_for(
    lambda: "草稿冲突" in gui("return value of every static text of scroll area 2 of group 1 of window 1"),
    "dirty draft did not show conflict",
)
click_identifier("parameter.adoptExternal")
wait_for(
    lambda: (
        gui('return value of (first text field of scroll area 2 of group 1 of window 1 whose description is "名称")')
        == "Concurrent J1"
    ),
    "external conflict resolution failed",
)
print("Native parameter draft refresh/conflict/resolution passed.")

click_identifier("configuration.export")
wait_for(lambda: gui("return count of sheets of window 1") != "0", "save panel did not appear")
go_to_path(directory)
gui("""set value of text field 1 of splitter group 1 of sheet 1 of window 1 to "exported-config.json"
click button "导出" of splitter group 1 of sheet 1 of window 1""")
exported = directory / "exported-config.json"
wait_for(lambda: exported.exists(), "export file not created")
raw = json.loads(exported.read_text())
# SurfaceConfiguration v7 also carries pages, macros and the active page; never a map or credentials.
if (
    not {"version", "name", "parameters", "assignments"}
    <= set(raw)
    <= {"version", "name", "parameters", "assignments", "pages", "macros", "activePageID"}
):
    raise RuntimeError("export contains data outside SurfaceConfiguration")
print("Native NSSavePanel export passed; no hardware map or credentials.")

bad = directory / "invalid.json"
bad.write_text('{"version":999}')
before = client.call("get_parameter", {"id": "arm.j1"})
click_identifier("configuration.import")
select_path(bad, "导入")
wait_for(
    lambda: "失败" in gui("return value of every static text of group 1 of window 1"),
    "invalid import did not show an error",
)
if client.call("get_parameter", {"id": "arm.j1"}) != before:
    raise RuntimeError("invalid import replaced the parameter")

candidate = copy.deepcopy(raw)
candidate["name"] = "Imported integration profile"
for parameter in candidate["parameters"]:
    if parameter["id"] == "arm.j1":
        parameter["name"] = "Imported J1"
        parameter["defaultValue"] = 45
path = directory / "valid.json"
path.write_text(json.dumps(candidate))
click_identifier("configuration.import")
select_path(path, "导入")
wait_for(
    lambda: "替换当前全部参数与分配？" in gui("return entire contents of window 1"),
    "import confirmation did not appear",
)
gui('perform action "AXPress" of button 2 of sheet 1 of window 1')
wait_for(
    lambda: client.call("get_parameter", {"id": "arm.j1"})["name"] == "Imported J1", "valid import was not applied"
)
if client.call("get_parameter", {"id": "arm.j1"})["value"] != 45:
    raise RuntimeError("import did not restore parameter default")
if [entry["binding"] for entry in client.call("list_controls")] != binding_before:
    raise RuntimeError("import changed the hardware mapping")
print("Native NSOpenPanel invalid/valid import and confirmation passed; hardware bindings preserved.")
