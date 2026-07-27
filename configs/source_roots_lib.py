#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
FREECM_ROOT = REPO_ROOT / "FreeCM"
if str(FREECM_ROOT) not in sys.path:
    sys.path.insert(0, str(FREECM_ROOT))

from repomgrswift.source_roots import (  # noqa: E402
    DependencyRootSpec,
    DependencyRootWorkflow,
    DependencyRootWorkflowConfig,
    DependencyResolution,
)


DEV_MODE_KEY = "DevMode"
BUILD_SETTING_KEYS = (
    "XCODE_DEVELOPMENT_TEAM",
    "MARKETING_VERSION",
    "ARCHIVE_ID",
)

SOURCE_ROOT_SPECS: tuple[DependencyRootSpec, ...] = ()
KNOWN_SOURCE_ROOT_SPECS: tuple[DependencyRootSpec, ...] = SOURCE_ROOT_SPECS

WORKFLOW = DependencyRootWorkflow(
    DependencyRootWorkflowConfig(
        repo_root=REPO_ROOT,
        dependency_root_specs=SOURCE_ROOT_SPECS,
        known_dependency_root_specs=KNOWN_SOURCE_ROOT_SPECS,
        app_config_keys=(*BUILD_SETTING_KEYS, DEV_MODE_KEY),
        repo_display_name="BCR Agent Console",
        xcode_manual_sync_command="`python3 configs/source_root_workflow.py --update`",
    ),
)


__all__ = (
    "BUILD_SETTING_KEYS",
    "DEV_MODE_KEY",
    "DependencyResolution",
    "FREECM_ROOT",
    "KNOWN_SOURCE_ROOT_SPECS",
    "REPO_ROOT",
    "SOURCE_ROOT_SPECS",
    "WORKFLOW",
)
