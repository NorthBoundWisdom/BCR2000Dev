#!/usr/bin/env python3
"""Development compatibility entry; consumers use the published diagnostic CLI."""

from pathlib import Path

_implementation = Path(__file__).resolve().parents[1] / "Support" / "NativeDiagnostics" / "bcr_protocol.py"
exec(compile(_implementation.read_bytes(), str(_implementation), "exec"), globals())
