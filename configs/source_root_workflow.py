#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
FREECM_ROOT = REPO_ROOT / "FreeCM"
for path in (REPO_ROOT, FREECM_ROOT):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from configs.setup_local_project import main as setup_local_project_main  # noqa: E402
from configs.source_roots_lib import WORKFLOW  # noqa: E402
from freecm.source_root_workflow import SourceRootWorkflowScript  # noqa: E402


SCRIPT = SourceRootWorkflowScript(
    WORKFLOW,
    repo_display_name="BCR Agent Console",
    update_callback=setup_local_project_main,
)


if __name__ == "__main__":
    raise SystemExit(SCRIPT.main())
