#!/usr/bin/env python3
"""Launch the actual virtual GUI and connect the locked SDK's display-only demo via private pipes."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import select
import subprocess
import sys
import time


class GUIProcess:
    def __init__(self, app: Path, output: Path, *, capacity: int | None = None):
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.token = secrets.token_hex(32)
        token_read, token_write = os.pipe()
        ready_read, ready_write = os.pipe()
        os.write(token_write, self.token.encode("ascii"))
        os.close(token_write)
        self.log = (self.output / "gui-stderr.log").open("w")
        self.buffer = b""
        command = [
            str(app.resolve() / "Contents/MacOS/BCRAgentConsole"),
            "--gui-virtual-surface",
            "--gui-virtual-surface-token-fd",
            str(token_read),
            "--gui-virtual-surface-ready-fd",
            str(ready_write),
        ]
        if capacity is not None:
            command += ["--surface-input-event-capacity", str(capacity)]
        try:
            self.process = subprocess.Popen(
                command, pass_fds=(token_read, ready_write), stdout=subprocess.DEVNULL, stderr=self.log
            )
        except BaseException:
            os.close(ready_read)
            self.log.close()
            raise
        finally:
            os.close(token_read)
            os.close(ready_write)
        self.reader = ready_read
        try:
            self.ready = self.record(15)
            if self.ready.get("event") != "gui_virtual.ready" or self.ready.get("source") != "simulation":
                raise RuntimeError("GUI virtual readiness was not confirmed")
            (self.output / "ready.json").write_text(json.dumps(self.ready, indent=2) + "\n")
        except BaseException:
            self.stop_unconfirmed()
            raise

    def record(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            if not select.select([self.reader], [], [], max(0, deadline - time.monotonic()))[0]:
                raise RuntimeError("GUI virtual readiness pipe timed out")
            part = os.read(self.reader, 65536)
            if not part or len(self.buffer) + len(part) > 131072:
                raise RuntimeError("GUI virtual readiness pipe ended or exceeded its bound")
            self.buffer += part
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def cli(self, sdk: Path, *, protocol: str, duration: float, extra=(), url=None):
        token_read, token_write = os.pipe()
        os.write(token_write, self.token.encode("ascii"))
        os.close(token_write)
        command = [
            sys.executable,
            "-m",
            "surface_panel_demo",
            "--url",
            url or self.ready["url"],
            "--instance-id",
            self.ready["instance_id"],
            "--mapping",
            self.ready["mapping_path"],
            "--token-fd",
            str(token_read),
            "--protocol",
            protocol,
            "--provider-id",
            self.ready["provider_id"],
            "--provider-header",
            "BCR-Provider-Id",
            "--duration",
            str(duration),
            *extra,
        ]
        try:
            return subprocess.Popen(
                command,
                pass_fds=(token_read,),
                cwd=self.output,
                env={**os.environ, "PYTHONPATH": str(sdk.resolve()), "PYTHONDONTWRITEBYTECODE": "1"},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        finally:
            os.close(token_read)

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            final = self.record(8)
            self.process.wait(timeout=8)
            (self.output / "stopped.json").write_text(json.dumps(final, indent=2) + "\n")
            if final.get("event") != "gui_virtual.stopped" or final.get("cleanup_failed") or self.process.returncode:
                raise RuntimeError("GUI virtual cleanup was not confirmed")
            return final
        finally:
            self.stop_unconfirmed()

    def stop_unconfirmed(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                final = self.record(8)
                (self.output / "unconfirmed-stop.json").write_text(json.dumps(final, indent=2) + "\n")
                self.process.wait(timeout=8)
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
                if self.process.poll() is None:
                    self.process.kill()
                    self.process.wait(timeout=5)
        if self.reader >= 0:
            os.close(self.reader)
            self.reader = -1
        self.log.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--protocol", choices=("2025-11-25", "2026-07-28"), default="2026-07-28")
    parser.add_argument("--duration", type=float, default=15)
    parser.add_argument("--input-event-capacity", type=int)
    args = parser.parse_args(argv)
    gui = GUIProcess(args.app, args.output, capacity=args.input_event_capacity)
    try:
        child = gui.cli(args.sdk, protocol=args.protocol, duration=args.duration)
        try:
            stdout, stderr = child.communicate(timeout=args.duration + 30)
        except BaseException:
            child.terminate()
            try:
                child.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                child.kill()
                child.communicate(timeout=5)
            raise
        (gui.output / "cli-stdout.json").write_text(stdout)
        (gui.output / "cli-stderr.json").write_text(stderr)
        status = child.returncode
        gui.stop()
        print(
            json.dumps(
                {
                    "source": "simulation",
                    "physical_evidence": False,
                    "gui_pid": gui.process.pid,
                    "cli_exit_code": status,
                    "output": str(gui.output),
                }
            )
        )
        return status
    finally:
        gui.stop_unconfirmed()


if __name__ == "__main__":
    raise SystemExit(main())
