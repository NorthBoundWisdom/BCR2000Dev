#!/usr/bin/env python3
"""Read-only consumer assembly check; run with python3 -B. No Pipe platform is started."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    sys.dont_write_bytecode = True
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", type=Path, required=True)
    parser.add_argument("--configuration", type=Path, default=ROOT / "examples/simulation/chassis-controls.json")
    parser.add_argument("--roles", type=Path, default=ROOT / "examples/simulation/chassis-roles.json")
    parser.add_argument("--pipe-root", type=Path, default=Path.home() / "Documents/RobimPipe/robimweld_pipe")
    parser.add_argument("--sdk", type=Path, default=ROOT / "build/seed/SurfacePlugins/clients/python")
    args = parser.parse_args()
    driver = args.pipe_root / "drivers/bcr_provider"
    if not (driver / "pipe_bcr_provider/surface_sim/roles.py").is_file():
        print("SKIP: Pipe consumer source is unavailable")
        return
    discovery = json.loads(
        subprocess.check_output(
            [
                str(args.provider.resolve()),
                "--simulation-configuration",
                str(args.configuration.resolve()),
                "--describe-surface",
            ],
            cwd=args.provider.resolve().parent,
            text=True,
        )
    )["discovery"]
    sys.path[:0] = [str(driver), str(args.sdk.resolve())]
    from pipe_bcr_provider.surface_sim.roles import resolve_chassis_roles
    from surface_control import mapping_revision

    binding = resolve_chassis_roles(json.loads(args.roles.read_text()), discovery, mapping_revision=mapping_revision)
    print(
        json.dumps(
            {
                "passed": True,
                "profile_id": binding.profile_id,
                "mapping_revision": binding.mapping_revision,
                "roles": [
                    binding.enable.control_id,
                    binding.linear.control_id,
                    binding.steer.control_id,
                    binding.stop_control_id,
                ],
                "feedback": {key: value.control_id for key, value in binding.feedback.items()},
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
