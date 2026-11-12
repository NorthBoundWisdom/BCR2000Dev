"""Publish a complete surface delivery and update the shared convention-1 index."""

from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import tempfile
import time


FIELDS = {
    "host",
    "path",
    "manifest_sha256",
    "contract_version",
    "sdk_version",
    "source_commit",
    "surface_plugins_revision",
    "profile_id",
    "profile_version",
    "generated_at",
}


def key(entry):
    return entry["host"], entry["source_commit"], entry["contract_version"]


def validate_index(value):
    if (
        not isinstance(value, dict)
        or type(value.get("schema_version")) is not int
        or value.get("schema_version") != 1
        or not isinstance(value.get("deliveries"), list)
    ):
        raise ValueError("Malformed delivery index")
    keys, paths = set(), set()
    for entry in value["deliveries"]:
        if (
            not isinstance(entry, dict)
            or not FIELDS <= entry.keys()
            or any(not isinstance(entry[field], str) or not entry[field] for field in FIELDS)
        ):
            raise ValueError("Malformed delivery index entry")
        patterns = {
            "host": r"[a-z0-9-]+",
            "manifest_sha256": r"[0-9a-f]{64}",
            "source_commit": r"[0-9a-f]{40}",
            "surface_plugins_revision": r"[0-9a-f]{40}",
            "contract_version": r"[0-9]+\.[0-9]+",
            "sdk_version": r"[0-9]+\.[0-9]+\.[0-9]+",
        }
        if any(re.fullmatch(pattern, entry[field]) is None for field, pattern in patterns.items()):
            raise ValueError("Malformed delivery index identity/hash")
        name = entry["path"]
        wanted = f"{entry['host']}-surface-{entry['contract_version']}-{entry['source_commit'][:7]}"
        if name != wanted:
            raise ValueError("Malformed delivery index path")
        try:
            if (
                re.fullmatch(
                    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z", entry["generated_at"]
                )
                is None
            ):
                raise ValueError("Missing UTC timestamp")
            datetime.fromisoformat(entry["generated_at"].replace("Z", "+00:00"))
        except ValueError as error:
            raise ValueError("Malformed delivery index generation time") from error
        if key(entry) in keys or name in paths:
            raise ValueError("Duplicate delivery index key/path")
        keys.add(key(entry))
        paths.add(name)
    return value


@contextmanager
def index_lock(root, timeout=30):
    lock = root / ".index.lock"
    token = secrets.token_hex(16)
    deadline = time.monotonic() + timeout
    while True:
        try:
            lock.mkdir(mode=0o700)
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise TimeoutError("Delivery index lock is busy; inspect its owner before recovery") from None
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    identity = lock.stat(follow_symlinks=False)
    try:
        (lock / "owner.json").write_text(json.dumps({"pid": os.getpid(), "token": token}) + "\n")
        yield
    finally:
        # Never release a successor's lock if this directory was replaced while we worked.
        try:
            current = lock.stat(follow_symlinks=False)
            owner = json.loads((lock / "owner.json").read_text())
            if (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino) and owner.get("token") == token:
                (lock / "owner.json").unlink()
                lock.rmdir()
        except FileNotFoundError:
            pass


def strict_json(text):
    def object_pairs(pairs):
        value = {}
        for name, item in pairs:
            if name in value:
                raise ValueError("Duplicate JSON object key in delivery metadata")
            value[name] = item
        return value

    def invalid_constant(_):
        raise ValueError("Nonfinite JSON constant in delivery metadata")

    return json.loads(text, object_pairs_hook=object_pairs, parse_constant=invalid_constant)


def read_index(root):
    path = root / "INDEX.json"
    if path.is_symlink():
        raise ValueError("Delivery index must not be a symbolic link")
    if not path.exists():
        return {"schema_version": 1, "deliveries": []}
    return validate_index(strict_json(path.read_text()))


def write_index(root, value):
    validate_index(value)
    descriptor, name = tempfile.mkstemp(prefix=".INDEX-", suffix=".json", dir=root)
    path = Path(name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(path, root / "INDEX.json")
    finally:
        path.unlink(missing_ok=True)


def publish(root, builder, *, host="bcr2000", lock_timeout=30):
    """Build privately, then serialize directory publication plus atomic index replacement.

    A failed index write restores the prior directory; readers verify the manifest hash and
    fail closed during the brief directory replacement interval.
    """
    root = Path(root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".surface-build-", dir=root))
    staged, previous = staging / "delivery", staging / "previous"
    published = False
    try:
        manifest = builder(staged)
        commit, contract = manifest["source_commit"], manifest["surface_control_contract"]
        name = f"{host}-surface-{contract}-{commit[:7]}"
        destination = root / name
        entry = {
            "host": host,
            "path": name,
            "manifest_sha256": hashlib.sha256((staged / "manifest.json").read_bytes()).hexdigest(),
            "contract_version": contract,
            "sdk_version": manifest["surface_control_sdk"],
            "source_commit": commit,
            "surface_plugins_revision": manifest["surface_plugins_revision"],
            "profile_id": manifest["profile_id"],
            "profile_version": manifest["profile_version"],
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        }
        validate_index({"schema_version": 1, "deliveries": [entry]})
        with index_lock(root, lock_timeout):
            index = read_index(root)
            if any(row["path"] == name and key(row) != key(entry) for row in index["deliveries"]):
                raise ValueError("Delivery name collides with a different full source commit")
            if destination.is_symlink():
                raise ValueError("Delivery destination must not be a symbolic link")
            if destination.exists():
                old = strict_json((destination / "manifest.json").read_text())
                if old.get("source_commit") != commit or old.get("surface_control_contract") != contract:
                    raise ValueError("Delivery destination belongs to a different full source commit")
                os.replace(destination, previous)
            try:
                os.replace(staged, destination)
                # Reread under the same lock immediately before the read/modify/write.
                index = read_index(root)
                index["deliveries"] = sorted(
                    [row for row in index["deliveries"] if key(row) != key(entry)] + [entry], key=key
                )
                write_index(root, index)
                published = True
            except BaseException:
                if destination.exists():
                    shutil.rmtree(destination)
                if previous.exists():
                    os.replace(previous, destination)
                raise
        return manifest, destination, entry
    finally:
        if previous.exists() and not published:
            raise RuntimeError(f"Delivery rollback failed; previous delivery preserved at {previous}")
        shutil.rmtree(staging)
