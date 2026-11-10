#!/usr/bin/env python3
"""Format tracked source/text, or safely auto-fix staged files before a commit."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
SKIP_PREFIXES = ("configs/_vendor/",)


def git(root: Path, *args: str, data: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], cwd=root, input=data, capture_output=True, check=True).stdout


def candidates(root: Path, staged: bool) -> list[str]:
    command = ("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z") if staged else ("ls-files", "-z")
    paths = [os.fsdecode(item) for item in git(root, *command).split(b"\0") if item]
    paths = [path for path in paths if not path.startswith(SKIP_PREFIXES)]
    if not paths:
        return []
    attributes = git(
        root,
        "check-attr",
        "--cached",
        "-z",
        "--stdin",
        "text",
        data=b"".join(os.fsencode(path) + b"\0" for path in paths),
    ).split(b"\0")[:-1]
    if len(attributes) != len(paths) * 3:
        raise RuntimeError("Git returned incomplete text attributes")
    return [path for path, attribute in zip(paths, attributes[2::3]) if attribute != b"unset"]


def normalize(data: bytes, markdown: bool = False) -> bytes:
    data = data.replace(b"\r\n", b"\n")
    # Two trailing spaces are a Markdown hard line break.
    data = re.sub(
        rb"[ \t]+(?=\n|$)",
        lambda match: b"  " if markdown and match[0].endswith(b"  ") else b"",
        data,
    )
    return data.rstrip(b"\n") + b"\n" if data else data


def format_content(root: Path, path: str, data: bytes) -> bytes:
    suffix = Path(path).suffix.lower()
    if suffix == ".swift":
        command = [
            "swiftformat",
            "stdin",
            "--stdin-path",
            path,
            "--config",
            str(root / "configs/.swiftformat"),
            "--quiet",
        ]
    elif suffix == ".py":
        command = ["ruff", "format", "--config", str(root / "ruff.toml"), "--stdin-filename", path, "-"]
    else:
        return normalize(data, suffix == ".md")
    if shutil.which(command[0]) is None:
        raise RuntimeError(f"{command[0]} is required to format {path}; see CONTRIBUTING.md")
    result = subprocess.run(command, cwd=root, input=data, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{path}: {result.stderr.decode(errors='replace').strip()}")
    # Source formatters understand string literals; generic whitespace cleanup
    # could change significant spaces inside multiline strings.
    return result.stdout


def format_repository(root: Path, *, staged: bool = False, check: bool = False) -> int:
    changes = []
    for relative in candidates(root, staged):
        path = root / relative
        # Never follow symlinks, including a symlink in a parent directory.
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            continue
        if any((root / parent).is_symlink() for parent in Path(relative).parents):
            continue
        if staged:
            entry = git(root, "ls-files", "--stage", "-z", "--", relative).split(b"\0")[0]
            if not entry.startswith((b"100644 ", b"100755 ")):
                continue
            original = git(root, "show", f":{relative}")
        else:
            original = path.read_bytes()
        if b"\0" in original:
            continue
        try:
            original.decode("utf-8")
        except UnicodeDecodeError:
            continue
        formatted = format_content(root, relative, original)
        if formatted != original:
            changes.append((relative, original, formatted))
    if check:
        for relative, _, _ in changes:
            print(f"[format] Needs formatting: {relative}")
        return int(bool(changes))
    # Preflight every file before writing anything. Never absorb unstaged edits.
    if staged:
        partial = [relative for relative, original, _ in changes if (root / relative).read_bytes() != original]
        if partial:
            raise RuntimeError(
                "Partially staged files need formatting; format and stage the intended changes first: "
                + ", ".join(partial)
            )
    for relative, _, formatted in changes:
        (root / relative).write_bytes(formatted)
        print(f"[format] Updated: {relative}")
    if staged and changes:
        print("[format] Auto-format complete. Re-stage the updated files and retry the commit; the index is unchanged.")
        return 1
    print(f"[format] Complete: {len(changes)} file(s) updated.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    scope = parser.add_mutually_exclusive_group(required=True)
    scope.add_argument("--all", action="store_true", help="format all tracked files")
    scope.add_argument("--staged", action="store_true", help="auto-fix staged files; stop for re-staging after changes")
    parser.add_argument("--check", action="store_true", help="report formatting changes without writing files")
    args = parser.parse_args()
    try:
        return format_repository(REPO_ROOT, staged=args.staged, check=args.check)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"[format] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
