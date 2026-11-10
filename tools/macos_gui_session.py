#!/usr/bin/env python3
"""Run diagnostics in this user\'s GUI bootstrap session, then remove only our job.

Use when SSH and the logged-in desktop have different CoreMIDI visibility.
Does not restart MIDIServer, alter login settings, install a persistent agent,
change another user\'s session or elevate privileges.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid


def run(arguments, timeout=300):
    domain = f"gui/{os.getuid()}"
    check = subprocess.run(["launchctl", "print", domain], capture_output=True, text=True)
    if check.returncode:
        raise RuntimeError("No accessible GUI login session for this user; log in locally before this optional path")
    label = "dev.bcragentconsole.diagnostics." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="bcr-gui-") as temporary:
        root = Path(temporary)
        os.chmod(root, 0o700)
        complete = root / "complete.json"
        stdout, stderr = root / "stdout.txt", root / "stderr.txt"
        for path in (stdout, stderr):
            path.touch(mode=0o600)
        command = [
            sys.executable,
            str(Path(__file__).with_name("macos_test_session.py")),
            *arguments,
            "--completion-file",
            str(complete),
        ]
        plist = root / "job.plist"
        with plist.open("wb") as stream:
            plistlib.dump(
                {
                    "Label": label,
                    "ProgramArguments": command,
                    "RunAtLoad": True,
                    "ProcessType": "Background",
                    "LimitLoadToSessionType": "Aqua",
                    "WorkingDirectory": str(Path.cwd()),
                    "EnvironmentVariables": {"BCR_DIAGNOSTIC_GUI": "1"},
                    "StandardOutPath": str(stdout),
                    "StandardErrorPath": str(stderr),
                },
                stream,
            )
        os.chmod(plist, 0o600)
        started = False
        summary = None
        cleanup = None
        try:
            launch = subprocess.run(["launchctl", "bootstrap", domain, str(plist)], capture_output=True, text=True)
            if launch.returncode:
                raise RuntimeError("Cannot launch user GUI job: " + launch.stderr.strip())
            started = True
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if complete.exists():
                    summary = json.loads(complete.read_text())
                    break
                state = subprocess.run(["launchctl", "print", domain + "/" + label], capture_output=True, text=True)
                if state.returncode or ("state = not running" in state.stdout and "last exit code" in state.stdout):
                    if complete.exists():
                        summary = json.loads(complete.read_text())
                        break
                    raise RuntimeError("GUI worker exited without a completion report: " + stderr.read_text()[-2000:])
                time.sleep(0.2)
            if summary is None:
                raise RuntimeError("GUI worker deadline exceeded; hardware restoration is not assumed")
        finally:
            if started:
                removed = subprocess.run(["launchctl", "bootout", domain + "/" + label], capture_output=True, text=True)
                cleanup = removed.returncode == 0
                if not cleanup:
                    raise RuntimeError(
                        "Could not remove temporary GUI job " + domain + "/" + label + ": " + removed.stderr.strip()
                    )
        summary["temporaryGUIJobRemoved"] = cleanup
        return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    if sys.platform != "darwin" or not 30 <= args.timeout <= 600:
        parser.error("macOS and a 30..600 second deadline are required")
    if any(value == "--completion-file" or value.startswith("--completion-file=") for value in arguments):
        parser.error("Completion marker is managed by this wrapper")
    worker_deadline = 240
    for index, value in enumerate(arguments):
        if value == "--deadline" and index + 1 < len(arguments):
            worker_deadline = int(arguments[index + 1])
        elif value.startswith("--deadline="):
            worker_deadline = int(value.split("=", 1)[1])
    if worker_deadline + 20 > args.timeout:
        parser.error("GUI timeout must exceed the worker deadline by at least 20 seconds")
    summary = run(arguments, args.timeout)
    print(json.dumps(summary))
    return summary["exitCode"]


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError) as error:
        print("ERROR:", error, file=sys.stderr)
        raise SystemExit(1)
