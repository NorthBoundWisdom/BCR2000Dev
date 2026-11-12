#!/usr/bin/env python3
"""Optional FreeCM plugin adapter for local setup and explicit build cleanup."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from configs.setup_local_project import main as setup_main  # noqa: E402

# Excludes Codex schemas, runtime data and the retired local checkout.
CLEAN_TARGETS = ("configured.json", "seed-build", "swiftpm", "app", "package", "package-staging", "icons", "smoke")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--init", action="store_true")
    action.add_argument("--update", action="store_true")
    action.add_argument("--cleanbuild", action="store_true")
    parser.add_argument("--quiet", action="store_true", help="Accepted for plugin invocations.")
    parser.add_argument("--dry-run", action="store_true", help="Preview build cleanup.")
    args = parser.parse_args(argv)
    if args.dry_run and not args.cleanbuild:
        parser.error("--dry-run requires --cleanbuild")
    if not args.cleanbuild:
        return setup_main()
    build = REPO_ROOT / "build"
    if build.is_symlink():
        raise ValueError("Refusing to clean a symlinked build directory.")
    for name in CLEAN_TARGETS:
        path = build / name
        if not path.exists() and not path.is_symlink():
            continue
        print(f"{'Would remove' if args.dry_run else 'Removing'} build/{name}")
        if not args.dry_run:
            if path.is_symlink() or path.is_file():
                path.unlink()
            else:
                shutil.rmtree(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
