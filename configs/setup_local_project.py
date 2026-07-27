#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
PACKAGE_MANIFEST = REPO_ROOT / "Package.swift"
FREECM_ROOT = REPO_ROOT / "FreeCM"
LOCK_TEMPLATE = REPO_ROOT / "source_roots.lock.jsonc.in"
ACTIVE_LOCK = REPO_ROOT / "source_roots.lock.jsonc"


def _run(command: list[str]) -> None:
    print(">>", " ".join(command), flush=True)
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        if completed.stdout:
            print(completed.stdout)
        if completed.stderr:
            print(completed.stderr)
        raise RuntimeError(
            f"Command failed with exit code {completed.returncode}: {' '.join(command)}"
        )


def main() -> int:
    if not FREECM_ROOT.is_dir():
        raise RuntimeError(
            "FreeCM submodule is missing. Run `git submodule update --init --recursive`."
        )
    if not PACKAGE_MANIFEST.is_file():
        raise RuntimeError("Package.swift is missing")
    if not LOCK_TEMPLATE.is_file():
        raise RuntimeError("source_roots.lock.jsonc.in is missing")

    if not ACTIVE_LOCK.exists():
        shutil.copy2(LOCK_TEMPLATE, ACTIVE_LOCK)
        print(f"Created local {ACTIVE_LOCK.name} from committed template.")

    _run(["swift", "package", "dump-package"])
    print("BCR Agent Console local configuration is ready.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
