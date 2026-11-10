"""Private, atomic diagnostics and bounded subprocess execution."""

import json
import os
from pathlib import Path
import subprocess
import time


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def command_stage(name, arguments, directory, timeout=30):
    started = time.monotonic()
    result = {"name": name, "status": "error"}
    try:
        completed = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
        result["exitCode"] = completed.returncode
        result["status"] = "ok" if completed.returncode == 0 else "error"
        stdout, stderr = completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as error:
        result.update(
            status="timeout",
            exitCode=None,
            error="Worker exceeded its deadline; hardware state is not assumed restored",
        )
        stdout = error.stdout or b""
        stderr = error.stderr or b""
        stdout = stdout.decode(errors="replace") if isinstance(stdout, bytes) else stdout
        stderr = stderr.decode(errors="replace") if isinstance(stderr, bytes) else stderr
    except OSError as error:
        stdout, stderr = "", str(error)
        result["error"] = str(error)
    for suffix, content in [("stdout", stdout), ("stderr", stderr)]:
        path = Path(directory) / f"{name}.{suffix}.txt"
        with path.open("x", encoding="utf-8") as stream:
            os.chmod(path, 0o600)
            stream.write(content)
        result[suffix] = path.name
    result["durationMs"] = round((time.monotonic() - started) * 1000)
    if result["status"] == "ok":
        try:
            result["data"] = json.loads(stdout)
        except (ValueError, TypeError):
            result["data"] = None
    return result
