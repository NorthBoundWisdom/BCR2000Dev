"""Build-tool compatibility import of the exact helper shipped beside packaged diagnostics."""

from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Support.NativeDiagnostics.surface_sdk_metadata import (  # noqa: E402
    ARTIFACT as ARTIFACT,
    METADATA_NAME as METADATA_NAME,
    SUPPORTED_SDKS as SUPPORTED_SDKS,
    create as create,
    embedded_version as embedded_version,
    load as load,
    validate as validate,
    validate_zip as validate_zip,
    verify_manifest as verify_manifest,
)
