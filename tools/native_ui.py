"""PID-scoped native accessibility helpers for isolated acceptance scripts."""

import json
import os
import re
import shutil
import uuid
from pathlib import Path
import subprocess
import time


def native_binary(stem="native_ui"):
    source = Path(__file__).with_name(stem + ".swift")
    binary = source.parent.parent / "build/tools" / stem
    if not binary.exists() or binary.stat().st_mtime_ns < source.stat().st_mtime_ns:
        binary.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", str(source), "-o", str(binary)], check=True)
    return binary


class DesktopAudit:
    """Finite sampling, scoped to the isolated PID, including startup and shutdown."""

    def __init__(self, directory, bundle_id=None):
        self.directory = Path(directory)
        if bundle_id:
            (self.directory / "desktop-audit-bundle.txt").write_text(bundle_id)
        self.process = subprocess.Popen(
            [str(native_binary("desktop_audit")), str(os.getpid()), str(directory)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 10
        while not (self.directory / "desktop-audit.ready").exists():
            if self.process.poll() is not None:
                raise RuntimeError("Desktop sampler failed: " + self.process.stderr.read())
            if time.monotonic() >= deadline:
                self.process.terminate()
                self.process.wait(timeout=3)
                raise RuntimeError("Desktop sampler did not become ready")
            time.sleep(0.02)

    def finish(self):
        (self.directory / "desktop-audit.stop").touch()
        _, errors = self.process.communicate(timeout=5)
        if self.process.returncode:
            raise RuntimeError("Desktop sampler failed: " + errors)
        result = json.loads((self.directory / "desktop-audit.json").read_text())
        if result["samples"] == 0 or not result["targetPIDs"] or result["targetWasFront"] or result["visibleSamples"]:
            raise RuntimeError("Offscreen desktop audit failed: " + json.dumps(result))
        print("Offscreen desktop audit:", json.dumps(result), flush=True)


class NativeUI:
    def __init__(self, pid):
        self.pid = int(pid)
        arguments = subprocess.check_output(["ps", "-p", str(self.pid), "-o", "args="], text=True)
        self.offscreen = "--offscreen" in arguments.split()

    def run(self, body):
        if self.offscreen:
            if re.search(r"\b(?:keystroke|key\s+(?:code|down|up))\b", body, re.IGNORECASE):
                raise RuntimeError("System keyboard events are forbidden in offscreen acceptance")
            body = "\n".join(
                line
                for line in body.splitlines()
                if not re.match(r"\s*set\s+(?:frontmost|position|focused)\b", line, re.IGNORECASE)
            )
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
        binary = native_binary()
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

    def press_help(self, prefix):
        if not self.command("press-help", prefix):
            raise RuntimeError(f"Accessibility help prefix missing: {prefix}")

    def press_description(self, prefix):
        if not self.command("press-description", prefix):
            raise RuntimeError(f"Accessibility description prefix missing: {prefix}")

    def capture(self, path, width=1680):
        if self.offscreen:
            nonce = str(uuid.uuid4())
            directory = Path(os.environ["BCR_INTEGRATION_DIRECTORY"])
            image = directory / f"capture-{nonce}.png"
            failure = directory / f"capture-{nonce}.error"
            self.command("snapshot", nonce)
            self.wait(lambda: image.exists() or failure.exists(), "App view rendering did not respond")
            if failure.exists():
                raise RuntimeError(failure.read_text())
            path = Path(path)
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(image, path)
            print("Rendered own App view", path.name, flush=True)
            return
        self.capture_windowserver(path, width)

    def capture_windowserver(self, path, width=1680):
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
    def wait_settled(check, message, duration=0.3, timeout=12):
        deadline = time.monotonic() + timeout
        stable_since = None
        while time.monotonic() < deadline:
            if check():
                stable_since = stable_since or time.monotonic()
                if time.monotonic() - stable_since >= duration:
                    return
            else:
                stable_since = None
            time.sleep(0.05)
        raise RuntimeError(message)

    @staticmethod
    def wait(check, message, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if check():
                return
            time.sleep(0.1)
        raise RuntimeError(message)
