"""Read the repository's optional, machine-local build environment without shell execution."""

from __future__ import annotations

from collections.abc import Iterator, Mapping
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re

REPO_ROOT = Path(__file__).resolve().parents[1]
LOCAL_FILE = "build.local.json"
EXAMPLE_FILE = "configs/build.local.example.json"
WINDOWS_ENVIRONMENT = os.name == "nt"
VARIABLE = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))|%([A-Za-z_][A-Za-z0-9_]*)%")


def ensure_local_build_environment(repo_root: Path | None = None) -> bool:
    """Copy the public example only when no local configuration exists."""
    root = repo_root if repo_root is not None else REPO_ROOT
    destination = root / LOCAL_FILE
    if destination.exists() or destination.is_symlink():
        return False
    try:
        example = (root / EXAMPLE_FILE).read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(f"Unable to read {EXAMPLE_FILE}: {error}") from error
    try:
        with destination.open("x", encoding="utf-8") as handle:
            handle.write(example)
    except FileExistsError:
        return False
    print(f"Created {LOCAL_FILE} from {EXAMPLE_FILE}; fill in local SDK and dependency paths.")
    return True


def load_build_environment(
    repo_root: Path | None = None, *, environ: Mapping[str, str] | None = None
) -> dict[str, str]:
    root = (repo_root if repo_root is not None else REPO_ROOT).resolve()
    inherited = dict(os.environ if environ is None else environ)
    path = root / LOCAL_FILE
    if not path.exists() and not path.is_symlink():
        return inherited
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"Unable to read {LOCAL_FILE}: {error}") from error
    if not isinstance(payload, dict) or set(payload) - {"environment", "path"}:
        raise ValueError(f"{LOCAL_FILE} accepts only environment and path fields.")
    variables, paths = payload.get("environment", {}), payload.get("path", [])
    if not isinstance(variables, dict) or any(
        not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key)
        or key.upper() in {"PATH", "REPO_ROOT"}
        or not isinstance(value, str) or any(char in value for char in "\r\n\0")
        for key, value in variables.items()
    ):
        raise ValueError(f"{LOCAL_FILE} environment must contain single-line string variables; use path for PATH.")
    if not isinstance(paths, list) or any(
        not isinstance(value, str) or not value.strip() or any(char in value for char in "\r\n\0")
        for value in paths
    ):
        raise ValueError(f"{LOCAL_FILE} path must be a list of nonempty single-line strings.")
    def normalize(name: str) -> str:
        return name.upper() if WINDOWS_ENVIRONMENT else name

    normalized_variables = {normalize(name): value for name, value in variables.items()}
    if len(normalized_variables) != len(variables):
        raise ValueError(f"{LOCAL_FILE}: duplicate environment variable names.")
    variables = normalized_variables
    inherited = {normalize(name): value for name, value in inherited.items()}
    resolved = dict(inherited)
    visiting: set[str] = set()

    def expand(value: str) -> str:
        def replace(match: re.Match[str]) -> str:
            name = normalize(next(part for part in match.groups() if part is not None))
            if name == "REPO_ROOT":
                return str(root)
            return resolve(name)
        value = VARIABLE.sub(replace, value)
        if value == "~" or value.startswith(("~/", "~\\")):
            home = inherited.get("HOME") or inherited.get("USERPROFILE")
            if not home:
                raise ValueError(f"{LOCAL_FILE}: home directory is unavailable for ~ expansion.")
            value = home + value[1:]
        return value

    def resolve(name: str) -> str:
        if name in resolved:
            return resolved[name]
        if name not in variables:
            raise ValueError(f"{LOCAL_FILE}: undefined environment variable {name}.")
        if name in visiting:
            raise ValueError(f"{LOCAL_FILE}: cyclic environment variable {name}.")
        visiting.add(name)
        resolved[name] = expand(variables[name])
        visiting.remove(name)
        return resolved[name]

    for name in variables:
        resolve(name)
    entries = [str((root / expand(value)).resolve()) for value in paths]
    entries.extend(resolved.get("PATH", "").split(os.pathsep))
    if paths:
        resolved["PATH"] = os.pathsep.join(dict.fromkeys(value for value in entries if value))
    return resolved


@contextmanager
def use_build_environment(repo_root: Path | None = None) -> Iterator[None]:
    """Apply build settings only for the duration of one command, then restore the caller."""
    previous = dict(os.environ)
    environment = load_build_environment(repo_root)
    os.environ.clear()
    os.environ.update(environment)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(previous)
