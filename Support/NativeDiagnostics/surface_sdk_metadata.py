"""Validate private SDK artifact facts without importing or executing delivered code."""

from __future__ import annotations

import ast
import hashlib
import json
from pathlib import PurePosixPath
import re
import zipfile

SUPPORTED_SDKS = frozenset({"1.4.0", "1.5.0"})
METADATA_NAME = "surface-sdk-metadata.json"
ARTIFACT = "surface-control-sdk-metadata"


def embedded_version(archive):
    body = archive.read("surface_control/__init__.py").decode("utf-8")
    values = [
        node.value.value
        for node in ast.parse(body).body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "__version__" for target in node.targets)
        and isinstance(node.value, ast.Constant)
        and isinstance(node.value.value, str)
    ]
    if len(values) != 1:
        raise ValueError("Delivered SDK has no unique literal version")
    return values[0]


def validate_zip(path, version, digest):
    if (
        not isinstance(version, str)
        or version not in SUPPORTED_SDKS
        or path.name != f"surface-control-sdk-{version}.zip"
    ):
        raise ValueError("Unsupported SDK version or noncanonical ZIP name")
    if not path.is_file() or path.is_symlink() or not re.fullmatch(r"[0-9a-f]{64}", digest or ""):
        raise ValueError("Invalid SDK resource or SHA-256")
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError("SDK ZIP hash differs from verified metadata")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or any(
            PurePosixPath(name).is_absolute()
            or ".." in PurePosixPath(name).parts
            or "\\" in name
            or "\x00" in name
            or PurePosixPath(name).as_posix() != name
            for name in names
        ):
            raise ValueError("Duplicate or escaping SDK member")
        allowed = {"surface_control", "surface_conformance", "surface_control_diagnostics", "surface_panel_demo"}
        if any(
            not PurePosixPath(name).parts
            or PurePosixPath(name).parts[0] not in allowed
            or any(part in {"tests", "fixtures", "__pycache__"} for part in PurePosixPath(name).parts)
            or PurePosixPath(name).suffix not in {".py", ".md", ".json"}
            or PurePosixPath(name).name == "sdk_1_4_0.py"
            for name in names
        ):
            raise ValueError("Runtime SDK contains a test-only or unknown package")
        if embedded_version(archive) != version:
            raise ValueError("SDK ZIP name/metadata and embedded version disagree")
    return path


def create(artifact, version, revision):
    if not isinstance(version, str) or version not in SUPPORTED_SDKS:
        raise ValueError("Unsupported SDK version")
    path = artifact / f"surface-control-sdk-{version}.zip"
    value = {
        "schema_version": 1,
        "artifact": ARTIFACT,
        "sdk_version": version,
        "sdk_zip": path.name,
        "sdk_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "surface_plugins_revision": revision,
    }
    validate(value, artifact)
    return value


def validate(value, artifact):
    if not isinstance(value, dict) or set(value) != {
        "schema_version",
        "artifact",
        "sdk_version",
        "sdk_zip",
        "sdk_sha256",
        "surface_plugins_revision",
    }:
        raise ValueError("Invalid SDK metadata shape")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1 or value["artifact"] != ARTIFACT:
        raise ValueError("Unsupported SDK metadata")
    version = value["sdk_version"]
    if (
        not isinstance(version, str)
        or version not in SUPPORTED_SDKS
        or value["sdk_zip"] != f"surface-control-sdk-{version}.zip"
    ):
        raise ValueError("Unsupported SDK metadata resource")
    if not isinstance(value["surface_plugins_revision"], str) or not re.fullmatch(
        r"[0-9a-f]{40}", value["surface_plugins_revision"]
    ):
        raise ValueError("SDK metadata requires the full shared source revision")
    path = artifact / value["sdk_zip"]
    if path.resolve().parent != artifact.resolve():
        raise ValueError("SDK resource escaped artifact")
    return validate_zip(path, version, value["sdk_sha256"])


def load(path):
    if path.is_symlink() or not path.is_file() or path.name != METADATA_NAME:
        raise ValueError("SDK metadata must be the canonical regular sidecar")

    def unique(pairs):
        result = {}
        for key, item in pairs:
            if key in result:
                raise ValueError("Duplicate SDK metadata key")
            result[key] = item
        return result

    value = json.loads(path.read_text(), object_pairs_hook=unique)
    validate(value, path.parent)
    return value


def verify_manifest(artifact, manifest):
    version = manifest.get("surface_control_sdk")
    if not isinstance(version, str) or version not in SUPPORTED_SDKS:
        raise ValueError("Unsupported artifact SDK version")
    path = artifact / f"surface-control-sdk-{version}.zip"
    validate_zip(path, version, manifest["files_sha256"].get(path.name))
    sidecar = artifact / METADATA_NAME
    if version == "1.5.0" or sidecar.exists():
        value = load(sidecar)
        if hashlib.sha256(sidecar.read_bytes()).hexdigest() != manifest["files_sha256"].get(METADATA_NAME):
            raise ValueError("SDK metadata not pinned by final artifact")
        if (
            value["sdk_version"] != version
            or value["sdk_sha256"] != manifest["files_sha256"][path.name]
            or value["surface_plugins_revision"] != manifest.get("surface_plugins_revision")
        ):
            raise ValueError("SDK sidecar and final artifact disagree")
    if "surface_plugins_materialized_revision" in manifest and manifest[
        "surface_plugins_materialized_revision"
    ] != manifest.get("surface_plugins_revision"):
        raise ValueError("Materialized and declared shared source disagree")
    return path, version
