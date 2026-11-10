#!/usr/bin/env python3
"""Configure the Swift application locally without downloading dependencies."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.app_build import load_app_build_settings  # noqa: E402
from configs.build_environment import ensure_local_build_environment, use_build_environment  # noqa: E402
from configs.validate_repo_commands import main as validate_commands  # noqa: E402


def main() -> int:
    ensure_local_build_environment(REPO_ROOT)
    with use_build_environment(REPO_ROOT):
        settings = load_app_build_settings(REPO_ROOT)
        if validate_commands([str(REPO_ROOT)]) != 0:
            return 1
        subprocess.run(["swift", "package", "dump-package"], cwd=REPO_ROOT, check=True, stdout=subprocess.DEVNULL)
        marker = REPO_ROOT / "build/configured.json"
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(json.dumps({"schema_version": 1, "app_build": settings}, indent=2) + "\n")
    subprocess.run(["git", "config", "--local", "core.hooksPath", "configs/githooks"], cwd=REPO_ROOT, check=True)
    print("BCR Agent Console local configuration is ready.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
