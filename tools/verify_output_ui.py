#!/usr/bin/env python3
"""Native WP6 acceptance hook with the standard-library UDP simulator."""

import os
from pathlib import Path
import re
import subprocess
import sys
import time
from mcp_smoke import Client
from native_ui import NativeUI

pid = int(os.environ["BCR_INTEGRATION_APP_PID"])
ui = NativeUI(pid)
if ui.offscreen:
    raise RuntimeError(
        "Output acceptance requires foreground: AXConfirm did not commit the numeric port editor without focus"
    )
directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])
client = Client(os.environ["BCR_MCP_URL"], os.environ["BCR_MCP_TOKEN"])


def gui(body):
    return ui.run(body.replace("window 1", "mainWindow"))


def safety():
    return client.call("get_status")["motionSafety"]


def wait_for(check, description, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.02)
    raise RuntimeError(description)


def press_help(text, area=None, sheet=False):
    container = (
        "group 1 of sheet 1 of window 1"
        if sheet
        else ("group 1 of window 1" if area is None else f"scroll area {area} of group 1 of window 1")
    )
    return gui(f'''repeat with i from 1 to count of buttons of {container}
if help of button i of {container} is "{text}" then
perform action "AXPress" of button i of {container}
return "pressed"
end if
end repeat
error "semantic button not found"''')


def debug_failure(kind, value, trace):
    try:
        (directory / "output-ui-tree.txt").write_text(gui("return entire contents of window 1"))
    except RuntimeError:
        pass
    sys.__excepthook__(kind, value, trace)


sys.excepthook = debug_failure
simulator = subprocess.Popen(
    [sys.executable, "tools/arm_sim.py", "--port", "0", "--speed", "15"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)
try:
    ready = simulator.stdout.readline()
    match = re.search(r"\('127\.0\.0\.1', (\d+)\)", ready)
    if not match:
        raise RuntimeError("simulator did not report its bound loopback port")
    port = int(match.group(1))
    gui("set frontmost to true\nset position of window 1 to {80, 80}\nset size of window 1 to {1200, 760}")
    press_help("设置 OSC 输出、软限位、速度和 LED 来源")
    wait_for(lambda: gui("return count of sheets of window 1") != "0", "output settings did not appear")
    gui(f'''set focused of text field "端口" of group 1 of sheet 1 of window 1 to true
set value of text field "端口" of group 1 of sheet 1 of window 1 to "{port}"
key code 48''')
    press_help("启动或停止经过安全门的 OSC 输出", sheet=True)
    wait_for(lambda: safety()["status"] == "disabled", "output did not connect and remain disabled")
    gui('perform action "AXPress" of button 1 of group 1 of sheet 1 of window 1')
    client.call("set_parameter", {"id": "arm.j1", "value": 90})
    time.sleep(0.15)
    if abs(client.call("get_parameter", {"id": "arm.j1"})["actualValue"]) > 1e-5:
        raise RuntimeError("disabled gate sent motion")
    press_help("操作 B2-1", area=1)
    wait_for(
        lambda: safety()["status"] == "ready" and safety()["outputs"].get("arm.j1", 0) > 0,
        "enabled gate did not produce limited output",
    )
    time.sleep(0.25)
    state = safety()
    if not (0 < state["actual"]["arm.j1"] < state["outputs"]["arm.j1"] < 90):
        raise RuntimeError("target/output/actual did not show velocity-limited progress")
    print("Native output connected while disabled; Mock enable opened one gate for MCP target writes.")
    press_help("操作 B2-1", area=1)
    wait_for(lambda: safety()["status"] == "disabled", "disable did not close gate", timeout=0.5)
    time.sleep(0.12)
    held = safety()["actual"]["arm.j1"]
    time.sleep(0.12)
    if abs(safety()["actual"]["arm.j1"] - held) > 1e-4:
        raise RuntimeError("simulator kept moving after disable")
    press_help("设置 OSC 输出、软限位、速度和 LED 来源")
    gui("click radio button 2 of radio group 1 of group 1 of sheet 1 of window 1")
    wait_for(lambda: client.call("get_status")["ledSource"] == "actual", "actual LED source did not activate")
    if client.call("get_parameter", {"id": "arm.j1"})["value"] != 90:
        raise RuntimeError("actual feedback overwrote target")
    controls = client.call("list_controls")
    ring = next(item for item in controls if item["label"] == "P1-1")["value"]
    if ring == 95:
        raise RuntimeError("actual LED projection still displayed the target")
    gui('perform action "AXPress" of button 1 of group 1 of sheet 1 of window 1')
    print("Native disable stopped simulated movement; actual LED projection preserved the software target.")
    time.sleep(0.3)
    press_help("操作 B2-1", area=1)
    wait_for(lambda: safety()["status"] == "ready", "gate did not re-enable")
    started = time.monotonic()
    simulator.terminate()
    simulator.wait(timeout=2)
    wait_for(
        lambda: safety()["status"] in {"heartbeatExpired", "disconnected", "waitingActual"},
        "receiver loss did not close gate within 500 ms",
        timeout=0.5,
    )
    elapsed = time.monotonic() - started
    if elapsed > 0.5:
        raise RuntimeError("receiver loss alarm exceeded 500 ms")
    print(f"Native receiver-loss gate alarm passed in {elapsed * 1000:.0f} ms.")
    simulator = subprocess.Popen(
        [sys.executable, "tools/arm_sim.py", "--port", str(port), "--speed", "15"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if "listening" not in simulator.stdout.readline():
        raise RuntimeError("simulator restart failed")
    # Some systems report UDP refusal immediately; others retain a ready socket
    # and use heartbeat expiry. Both recover only after fresh heartbeat/state.
    press_help("设置 OSC 输出、软限位、速度和 LED 来源")
    if safety()["status"] == "disconnected":
        press_help("启动或停止经过安全门的 OSC 输出", sheet=True)
    gui('perform action "AXPress" of button 1 of group 1 of sheet 1 of window 1')
    wait_for(lambda: safety()["status"] == "waitingRearm", "fresh receiver did not require an operator rearm")
    time.sleep(0.15)
    if abs(safety()["actual"]["arm.j1"]) > 1e-4:
        raise RuntimeError("receiver restarted with enable already high and began moving")
    press_help("操作 B2-1", area=1)
    wait_for(lambda: safety()["status"] == "disabled", "rearm did not observe enable off")
    time.sleep(0.3)
    press_help("操作 B2-1", area=1)
    wait_for(lambda: safety()["status"] == "ready", "operator off/on did not rearm receiver")
    if safety()["baseline"]["arm.j1"] > safety()["actual"]["arm.j1"] + 1e-4:
        raise RuntimeError("reconnect replayed the old output instead of seeding actual state")
    print("Native receiver restart stayed stopped until operator off/on, then seeded fresh actual state.")
finally:
    if simulator.poll() is None:
        simulator.terminate()
        simulator.wait(timeout=3)
