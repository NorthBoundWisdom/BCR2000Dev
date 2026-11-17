#!/usr/bin/env python3
"""Hash complete proof artifacts; remove only owned raw traces larger than 100 MB."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "build/test-runs"


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    passed = os.environ.get("BCR_COMPLETE_PROOF_OUTCOME") == "success"
    files = []
    for path in sorted(ROOT.rglob("*.jsonl")):
        digest = hashlib.sha256()
        count = 0
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
                count += block.count(b"\n")
        size = path.stat().st_size
        row = {
            "path": str(path.relative_to(ROOT)),
            "bytes": size,
            "records": count,
            "sha256": digest.hexdigest(),
            "removed_large_raw_trace": False,
        }
        if passed and size > 100_000_000:
            path.unlink()
            row["removed_large_raw_trace"] = True
        files.append(row)
    (ROOT / "raw-trace-index.json").write_text(json.dumps(files, indent=2) + "\n")


if __name__ == "__main__":
    main()
