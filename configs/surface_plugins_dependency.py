#!/usr/bin/env python3
"""Materialize one locked Git commit for SwiftPM, using only Python stdlib and Git."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

LOCK_FILE = "configs/surface_plugins.lock.json"
CACHE_PATH = "build/dependencies/SurfacePlugins"
MARKER = "surface-plugins-manager.json"
SOURCE_ENV = "SURFACE_PLUGINS_SOURCE"
LEGACY_SOURCE_ENV = "SURFACE_PLUGINS_PATH"
SHA = re.compile(r"[0-9a-f]{40}\Z")


class DependencyError(RuntimeError):
    """An explicit acquisition, ownership, or revision failure."""


def _git(directory: Path, *arguments: str, environ: dict[str, str] | None = None) -> str:
    environment = dict(os.environ if environ is None else environ)
    for key in (
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ):
        environment.pop(key, None)
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    result = subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", "-C", str(directory), *arguments],
        env=environment,
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise DependencyError(f"Git {arguments[0]} failed while preparing the locked SurfacePlugins dependency")
    return result.stdout.strip()


def _spec(root: Path) -> dict[str, object]:
    path = root / LOCK_FILE
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise DependencyError(f"Cannot read {LOCK_FILE}") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schemaVersion", "remote", "revision"}
        or type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != 1
        or not isinstance(value["remote"], str)
        or not value["remote"].startswith("https://")
        or any(char in value["remote"] for char in "\r\n\0")
        or not isinstance(value["revision"], str)
        or SHA.fullmatch(value["revision"]) is None
    ):
        raise DependencyError(
            "SurfacePlugins lock requires schemaVersion 1, an HTTPS remote and full lowercase commit SHA"
        )
    return value


def _parent(root: Path, *, create: bool) -> Path:
    for path in (root / "build", root / "build/dependencies"):
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise DependencyError(f"Refusing non-directory or symlink dependency parent: {path.name}")
        if create:
            path.mkdir(exist_ok=True)
        elif not path.is_dir():
            raise DependencyError("SurfacePlugins cache is missing; run the ensure command")
    return root / "build/dependencies"


@contextmanager
def _exclusive(parent: Path, *, read_only: bool = False):
    path = parent / ".SurfacePlugins.lock"
    if path.is_symlink():
        raise DependencyError("Refusing symlink dependency lock")
    descriptor = os.open(path, (os.O_RDONLY if read_only else os.O_CREAT | os.O_RDWR) | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise DependencyError("Dependency lock must be a regular file")
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(descriptor, (fcntl.LOCK_SH if read_only else fcntl.LOCK_EX) | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise DependencyError("Another SurfacePlugins dependency operation is still active")
                time.sleep(0.05)
        yield
    finally:
        os.close(descriptor)


def _owned(path: Path, environ: dict[str, str]) -> dict[str, object]:
    git = path / ".git"
    marker = git / MARKER
    if (
        path.is_symlink()
        or not path.is_dir()
        or git.is_symlink()
        or not git.is_dir()
        or marker.is_symlink()
        or not marker.is_file()
    ):
        raise DependencyError("Refusing a non-manager or symlink SurfacePlugins cache; no directory was reset")
    if any(entry.is_symlink() for entry in git.rglob("*")):
        raise DependencyError("Refusing symlinks inside dependency Git metadata")
    try:
        value = json.loads(marker.read_text())
    except (OSError, ValueError) as error:
        raise DependencyError("Invalid dependency ownership marker") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schemaVersion", "remote", "revision"}
        or type(value.get("schemaVersion")) is not int
        or value.get("schemaVersion") != 1
        or not isinstance(value.get("remote"), str)
        or not isinstance(value.get("revision"), str)
        or SHA.fullmatch(value["revision"]) is None
    ):
        raise DependencyError("Invalid dependency ownership marker")
    if Path(_git(path, "rev-parse", "--show-toplevel", environ=environ)).resolve() != path.resolve():
        raise DependencyError("Dependency Git worktree does not belong to its cache directory")
    if _git(path, "rev-parse", "HEAD", environ=environ) != value["revision"]:
        raise DependencyError("SurfacePlugins cache HEAD differs from its ownership marker; refusing reset")
    if _git(path, "status", "--porcelain=v1", "--untracked-files=all", "--ignored", environ=environ):
        raise DependencyError("SurfacePlugins cache is dirty; preserve changes and repair it explicitly")
    if not (path / "Package.swift").is_file() or (path / "Package.swift").is_symlink():
        raise DependencyError("Locked dependency does not contain a regular Package.swift")
    return value


def _source(root: Path, environ: dict[str, str], spec: dict[str, object]) -> str:
    preferred, legacy = environ.get(SOURCE_ENV), environ.get(LEGACY_SOURCE_ENV)
    paths = [str((root / value).resolve()) for value in (preferred, legacy) if value]
    if len(set(paths)) > 1:
        raise DependencyError(f"Conflicting {SOURCE_ENV} and {LEGACY_SOURCE_ENV} acquisition sources")
    if paths:
        source = Path(paths[0])
        if not source.is_dir():
            raise DependencyError("Local SurfacePlugins acquisition source is not a Git directory")
        # Fetch only committed objects, never copy the source's working files or dirty changes.
        _git(source, "cat-file", "-e", f"{spec['revision']}^{{commit}}", environ=environ)
        return str(source)
    return str(spec["remote"])


def _materialize(parent: Path, spec: dict[str, object], source: str, environ: dict[str, str]) -> Path:
    stage = Path(tempfile.mkdtemp(prefix=".SurfacePlugins-stage-", dir=parent))
    try:
        _git(stage, "init", "--quiet", environ=environ)
        _git(stage, "remote", "add", "origin", str(spec["remote"]), environ=environ)
        _git(stage, "fetch", "--no-tags", "--depth=1", "--", source, str(spec["revision"]), environ=environ)
        _git(stage, "checkout", "--quiet", "--detach", str(spec["revision"]), environ=environ)
        (stage / ".git" / MARKER).write_text(json.dumps(spec, sort_keys=True) + "\n")
        _owned(stage, environ)
        return stage
    except BaseException:
        shutil.rmtree(stage)
        raise


def ensure_dependency(
    repo_root: Path | None = None,
    *,
    environ: dict[str, str] | None = None,
    update: bool = False,
    verify_only: bool = False,
) -> Path:
    """Return the clean fixed build path; explicit update replaces only an owned clean old revision."""
    root = (repo_root if repo_root is not None else Path(__file__).resolve().parents[1]).resolve()
    environment = dict(os.environ if environ is None else environ)
    spec = _spec(root)
    # Validate override conflicts even on a cache hit, without contacting any source/remote.
    preferred, legacy = environment.get(SOURCE_ENV), environment.get(LEGACY_SOURCE_ENV)
    if preferred and legacy and (root / preferred).resolve() != (root / legacy).resolve():
        raise DependencyError(f"Conflicting {SOURCE_ENV} and {LEGACY_SOURCE_ENV} acquisition sources")
    parent = _parent(root, create=not verify_only)
    destination = root / CACHE_PATH
    with _exclusive(parent, read_only=verify_only):
        previous = None
        if destination.exists() or destination.is_symlink():
            previous = _owned(destination, environment)
            if previous == spec:
                return destination
            if not update or verify_only or previous["remote"] != spec["remote"]:
                raise DependencyError(
                    "SurfacePlugins cache differs from the lock; use the explicit update command on a clean owned cache"
                )
        elif verify_only:
            raise DependencyError("SurfacePlugins cache is missing; run the ensure command")
        stage = _materialize(parent, spec, _source(root, environment, spec), environment)
        backup = None
        try:
            if previous is not None:
                if _owned(destination, environment) != previous:
                    raise DependencyError("Dependency cache changed during acquisition; refusing replacement")
                # Keep the previous clean materialization until the new one is ready.
                backup = Path(tempfile.mkdtemp(prefix=".SurfacePlugins-previous-", dir=parent))
                backup.rmdir()
                destination.rename(backup)
            elif destination.exists() or destination.is_symlink():
                raise DependencyError("A dependency destination appeared during acquisition; preserving it")
            stage.rename(destination)
        except BaseException:
            if backup is not None and backup.exists() and not destination.exists():
                backup.rename(destination)
            if stage.exists():
                shutil.rmtree(stage)
            raise
        if backup is not None:
            _owned(backup, environment)
            shutil.rmtree(backup)
        return destination


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("ensure", "verify", "update"), nargs="?", default="ensure")
    args = parser.parse_args(argv)
    try:
        result = ensure_dependency(update=args.action == "update", verify_only=args.action == "verify")
        print(result.relative_to(Path(__file__).resolve().parents[1]))
        return 0
    except (DependencyError, OSError) as error:
        parser.exit(1, f"SurfacePlugins dependency: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
