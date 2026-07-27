"""Validated application metadata, independent of FreeCM and dependency locks."""

from __future__ import annotations

import json
from pathlib import Path
import re

from configs.build_environment import load_build_environment

REPO_ROOT = Path(__file__).resolve().parents[1]


def load_app_build_settings(repo_root: Path = REPO_ROOT) -> dict[str, str]:
    path = repo_root / "configs/app_build.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    keys = {"MARKETING_VERSION", "ARCHIVE_ID"}
    if not isinstance(payload, dict) or set(payload) != keys:
        raise ValueError("app_build.json requires MARKETING_VERSION and ARCHIVE_ID only.")
    environment = load_build_environment(repo_root)
    settings = {key: environment.get(key, payload[key]) for key in keys}
    version, archive = settings["MARKETING_VERSION"], settings["ARCHIVE_ID"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("MARKETING_VERSION must be a numeric major.minor.patch version.")
    if not isinstance(archive, str) or not re.fullmatch(r"[1-9][0-9]*", archive):
        raise ValueError("ARCHIVE_ID must be a positive integer string.")
    return settings
