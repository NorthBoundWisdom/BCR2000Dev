#!/usr/bin/env python3
"""Run native Mock acceptance in an explicit isolated Debug app, without user files/Keychain."""
import argparse
import json
import os
import plistlib
import shutil
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error

from mcp_smoke import Client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path("build/app/BCRAgentConsole.app"))
    parser.add_argument("--port", type=int, default=18787)
    parser.add_argument("--script", type=Path, help="optional acceptance script after standard MCP probes")
    parser.add_argument("--configuration-write", action="store_true")
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("--port must be 1024–65535")
    root = Path("build/mcp-integration").resolve()
    root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="case-", dir=root))
    settings = {
        "version": 1, "enabled": True, "port": args.port,
        "permissions": {"parameterWrite": True, "configurationWrite": args.configuration_write, "writesPerSecond": 1000},
    }
    (directory / "mcp-settings.json").write_text(json.dumps(settings))
    token = secrets.token_hex(32)
    environment = os.environ.copy()
    environment.update({
        "BCR_INTEGRATION_DIRECTORY": str(directory), "BCR_INTEGRATION_TOKEN": token,
        "BCR_MCP_TOKEN": token, "BCR_MCP_URL": f"http://127.0.0.1:{args.port}/mcp",
    })
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
    with info_path.open("wb") as destination:
        plistlib.dump(info, destination)
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)],
                   check=True, capture_output=True)
    with (directory / "app.log").open("w") as log:
        app = subprocess.Popen([str(executable), "--integration-test"], env=environment, stdout=log, stderr=subprocess.STDOUT)
        environment["BCR_INTEGRATION_APP_PID"] = str(app.pid)
        try:
            client = Client(environment["BCR_MCP_URL"], token)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if app.poll() is not None:
                    raise RuntimeError("isolated app exited before listening; inspect its app.log")
                try:
                    if client.rpc("ping")[0] == 200:
                        break
                except urllib.error.URLError:
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("isolated listener did not start on the configured port")
            for flags in ([], ["--legacy"]):
                subprocess.run([sys.executable, "tools/mcp_smoke.py", "--url", environment["BCR_MCP_URL"], *flags],
                               env=environment, check=True)
            if args.script:
                subprocess.run([sys.executable, str(args.script.resolve())], env=environment, check=True)
            print("Isolated native MCP acceptance passed; artifacts:", directory.relative_to(Path.cwd()))
        finally:
            app.terminate()
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print("Isolated MCP acceptance failed:", exc, file=sys.stderr)
        raise SystemExit(1)
