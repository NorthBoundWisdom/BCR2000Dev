"""PID-scoped native accessibility helpers for isolated acceptance scripts."""

import json
from pathlib import Path
import subprocess
import time


class NativeUI:
    def __init__(self, pid):
        self.pid = int(pid)

    def run(self, body):
        source = f"""tell application "System Events"
set targetProcess to first application process whose unix id is {self.pid}
tell targetProcess
set mainWindow to first window whose name starts with "BCRTest-"
{body}
end tell
end tell"""
        result = subprocess.run(["osascript", "-e", source], capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result.stdout.strip()

    def command(self, action, identifier):
        source = Path(__file__).with_suffix(".swift")
        binary = source.parent.parent / "build/tools/native_ui"
        if not binary.exists() or binary.stat().st_mtime_ns < source.stat().st_mtime_ns:
            binary.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", str(source), "-o", str(binary)], check=True)
        result = subprocess.run(
            [str(binary), str(self.pid), action, identifier], capture_output=True, text=True, timeout=15
        )
        if result.returncode not in (0, 3):
            raise RuntimeError(result.stderr.strip() or f"AX helper failed ({result.returncode})")
        return result.returncode == 0

    def exists(self, identifier):
        return self.command("exists", identifier)

    def enabled(self, identifier):
        return self.command("enabled", identifier)

    def press(self, identifier):
        print("AXPress", identifier, flush=True)
        if not self.command("press", identifier):
            raise RuntimeError(f"Accessibility identifier missing: {identifier}")

    def capture(self, path, width=1680):
        # Capture only the isolated main window. Other applications and desktop pixels are excluded.
        script = (
            'ObjC.import("CoreGraphics");'
            "var all=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(0,0)));"
            f"JSON.stringify(all.filter(w=>w.kCGWindowOwnerPID=={self.pid}&&w.kCGWindowLayer==0"
            f"&&w.kCGWindowBounds.Width=={width}).map(w=>w.kCGWindowNumber))"
        )
        result = subprocess.run(
            ["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True, check=True, timeout=15
        )
        identifiers = json.loads(result.stdout)
        if len(identifiers) != 1:
            raise RuntimeError(f"Expected one isolated main window, found {len(identifiers)}")
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        time.sleep(0.5)
        subprocess.run(["screencapture", "-x", "-o", f"-l{identifiers[0]}", str(path)], check=True)
        subprocess.run(["sips", "--resampleWidth", str(width), str(path)], capture_output=True, check=True)
        print("Captured", path.name, flush=True)

    @staticmethod
    def wait(check, message, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if check():
                return
            time.sleep(0.1)
        raise RuntimeError(message)
