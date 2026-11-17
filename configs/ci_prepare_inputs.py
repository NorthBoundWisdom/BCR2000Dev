#!/usr/bin/env python3
"""Normalize only verified managed Git inputs before CI compilation/cache save."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from configs.surface_plugins_dependency import ensure_dependency  # noqa: E402
from configs.control_surface_kit_dependency import ensure_dependency as ensure_kit_dependency  # noqa: E402


def main():
    for verify in (ensure_dependency, ensure_kit_dependency):
        # Origin, full locked revision, manager ownership and clean worktree are checked first.
        dependency = verify(ROOT, verify_only=True)
        stamp = int(subprocess.check_output(["git", "log", "-1", "--format=%ct", "HEAD"], cwd=dependency))
        paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=dependency).split(b"\0")
        restored = 0
        for raw in paths:
            if not raw:
                continue
            path = dependency / os.fsdecode(raw)
            if path.is_file() and not path.is_symlink():
                os.utime(path, (stamp, stamp))
                restored += 1
        print(f"Verified managed inputs: {dependency.name}; {restored} tracked mtimes; locked commit time {stamp}")
        # The timestamp operation must not alter any Git content or identity.
        verify(ROOT, verify_only=True)


if __name__ == "__main__":
    main()
