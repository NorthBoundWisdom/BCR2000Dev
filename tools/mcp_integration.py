#!/usr/bin/env python3
"""Run native Mock acceptance in an explicit isolated Debug app, without user files/Keychain."""

import argparse
import json
import os
import plistlib
import shutil
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error

from mcp_smoke import Client
from native_ui import DesktopAudit


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path("build/app/BCRAgentConsole.app"))
    parser.add_argument("--port", type=int, default=18787)
    parser.add_argument("--script", type=Path, help="optional acceptance script after standard MCP probes")
    parser.add_argument("--configuration-write", action="store_true")
    parser.add_argument("--connection-fixture", action="store_true", help="Use the Debug-only in-memory MIDI fixture")
    presentation = parser.add_mutually_exclusive_group()
    presentation.add_argument(
        "--offscreen",
        action="store_true",
        help="transparent, click-through background test windows; frame parking is best effort (default without --script)",
    )
    presentation.add_argument(
        "--foreground",
        action="store_true",
        help="ordinary visible window (default with --script; some scenarios require foreground)",
    )
    parser.add_argument(
        "--language",
        choices=("en", "zh-Hans"),
        default="zh-Hans",
        help="isolated app language (Chinese by default for existing UI acceptance scripts)",
    )
    args = parser.parse_args(argv)
    if not 1024 <= args.port <= 65535:
        parser.error("--port must be 1024–65535")
    return args


def uses_offscreen(args):
    # Keep scripted runs foreground by default: the documented matrix still has foreground-only scenarios.
    return args.offscreen or (not args.foreground and args.script is None)


def app_arguments(executable, args):
    return [
        str(executable),
        "--integration-test",
        *(["--connection-fixture"] if args.connection_fixture else []),
        *(["--offscreen"] if uses_offscreen(args) else []),
        "-AppleLanguages",
        f"({args.language})",
    ]


def stop_app(app, offscreen):
    if app.poll() is not None:
        return
    if offscreen:
        # An isolated fixture has no user documents to save or interactive quit flow to preserve.
        app.kill()
    else:
        app.terminate()
    try:
        app.wait(timeout=5)
    except subprocess.TimeoutExpired:
        app.kill()
        app.wait()


def startup_failure(app, directory, reason):
    """Capture evidence before cleanup changes the lifecycle phase or sends its own signal."""
    code = app.poll()
    status = str(code)
    if code is not None and code < 0:
        try:
            status += f" ({signal.Signals(-code).name})"
        except ValueError:
            status += " (unknown signal)"

    def tail(name, lines=30):
        path = directory / name
        return "".join(path.read_text(errors="replace").splitlines(True)[-lines:]) if path.exists() else ""

    audit_signals = tail("desktop-audit-signals.jsonl")
    report = (
        f"{reason}; pid={app.pid}, returncode={status}, phase={tail('lifecycle-phase.txt').strip()}\n"
        f"artifacts: {directory}\n"
        "desktop audit signal records (recorded before sending; results follow):\n"
        f"{audit_signals or '<none; signal sender unknown if externally terminated>\n'}"
        f"app.log tail (unbuffered startup markers):\n{tail('app.log') or '<empty; no app startup marker reached>\n'}"
    )
    (directory / "launch-failure.txt").write_text(report)
    return RuntimeError(report)


def main(argv=None):
    args = parse_arguments(argv)
    offscreen = uses_offscreen(args)
    root = Path("build/mcp-integration").resolve()
    root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="case-", dir=root))
    settings = {
        "version": 1,
        "enabled": True,
        "port": args.port,
        "permissions": {
            "parameterWrite": True,
            "configurationWrite": args.configuration_write,
            "writesPerSecond": 1000,
        },
    }
    if args.connection_fixture:
        settings["permissions"]["deviceControl"] = True
    (directory / "mcp-settings.json").write_text(json.dumps(settings))
    token = secrets.token_hex(32)
    environment = os.environ.copy()
    environment.update(
        {
            "BCR_INTEGRATION_DIRECTORY": str(directory),
            "BCR_INTEGRATION_TOKEN": token,
            "BCR_MCP_TOKEN": token,
            "BCR_MCP_URL": f"http://127.0.0.1:{args.port}/mcp",
        }
    )
    environment["BCR_INTEGRATION_OFFSCREEN"] = "1" if offscreen else "0"
    if args.connection_fixture:
        environment["BCR_CONNECTION_FIXTURE"] = "1"
    # Give this artifact a unique app/process identity so native automation cannot
    # accidentally resolve the production app with the same bundle identifier/name.
    bundle = directory / "Integration.app"
    shutil.copytree(args.bundle.resolve(), bundle)
    info_path = bundle / "Contents/Info.plist"
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    executable_name = "BCRTest-" + secrets.token_hex(4)
    original_executable = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
    executable = original_executable.with_name(executable_name)
    original_executable.rename(executable)
    info["CFBundleExecutable"] = executable_name
    info["CFBundleName"] = executable_name
    info["CFBundleDisplayName"] = executable_name
    info["CFBundleIdentifier"] = "dev.bcragentconsole.integration." + executable_name.lower()
    if offscreen:
        # AppKit must know this before SwiftUI starts. didFinishLaunching is too
        # late: a regular app can briefly activate and the strict auditor kills it.
        info["LSUIElement"] = True
    with info_path.open("wb") as destination:
        plistlib.dump(info, destination)
    subprocess.run(
        ["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)], check=True, capture_output=True
    )
    audit = (
        DesktopAudit(directory, prepare_ci_desktop=os.environ.get("GITHUB_ACTIONS") == "true") if offscreen else None
    )
    failed = True
    try:
        with (directory / "app.log").open("w") as log:
            (directory / "lifecycle-phase.txt").write_text("launch")
            app = subprocess.Popen(
                app_arguments(executable, args),
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            environment["BCR_INTEGRATION_APP_PID"] = str(app.pid)
            (directory / "app-pid.txt").write_text(str(app.pid))
            try:
                client = Client(environment["BCR_MCP_URL"], token)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if app.poll() is not None:
                        raise startup_failure(app, directory, "isolated app exited before listening")
                    try:
                        if client.rpc("ping")[0] == 200:
                            break
                    except urllib.error.URLError:
                        pass
                    time.sleep(0.1)
                else:
                    raise startup_failure(app, directory, "isolated listener did not start on the configured port")
                (directory / "lifecycle-phase.txt").write_text("protocol")
                for flags in ([], ["--legacy"]):
                    subprocess.run(
                        [sys.executable, "tools/mcp_smoke.py", "--url", environment["BCR_MCP_URL"], *flags],
                        env=environment,
                        check=True,
                    )
                if args.script:
                    (directory / "lifecycle-phase.txt").write_text("script")
                    subprocess.run([sys.executable, str(args.script.resolve())], env=environment, check=True)
            finally:
                (directory / "lifecycle-phase.txt").write_text("shutdown")
                stop_app(app, offscreen)
        failed = False
    finally:
        if audit:
            try:
                audit.finish()
            except RuntimeError as error:
                # Never let the audit replace the error that ended the run.
                if not failed:
                    raise
                print("Also:", error, file=sys.stderr)
    print("Isolated native MCP acceptance passed; artifacts:", directory.relative_to(Path.cwd()))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print("Isolated MCP acceptance failed:", exc, file=sys.stderr)
        raise SystemExit(1)
