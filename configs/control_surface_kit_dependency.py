#!/usr/bin/env python3
"""Fixed ControlSurfaceKit entry point for the shared managed Git dependency engine."""

from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from configs import managed_git_dependency as manager  # noqa: E402
from configs.managed_git_dependency import DependencyError, DependencyLayout  # noqa: E402,F401

LAYOUT = DependencyLayout(
    name="ControlSurfaceKit",
    lock_file="configs/control_surface_kit.lock.json",
    marker="control-surface-kit-manager.json",
    source_env="CONTROL_SURFACE_KIT_SOURCE",
    legacy_source_env="CONTROL_SURFACE_KIT_PATH",
)
LOCK_FILE = LAYOUT.lock_file
CACHE_PATH = LAYOUT.cache_path
MARKER = LAYOUT.marker
SOURCE_ENV = LAYOUT.source_env
LEGACY_SOURCE_ENV = LAYOUT.legacy_source_env


def _materialize(parent: Path, spec: dict[str, object], source: str, environ: dict[str, str]) -> Path:
    return manager._materialize(parent, spec, source, environ, LAYOUT)


def ensure_dependency(
    repo_root: Path | None = None,
    *,
    environ: dict[str, str] | None = None,
    update: bool = False,
    verify_only: bool = False,
) -> Path:
    return manager.ensure_dependency(
        repo_root, layout=LAYOUT, materialize=_materialize, environ=environ, update=update, verify_only=verify_only
    )


def main(argv: list[str] | None = None) -> int:
    return manager.main(argv, layout=LAYOUT, ensure=ensure_dependency)


if __name__ == "__main__":
    raise SystemExit(main())
