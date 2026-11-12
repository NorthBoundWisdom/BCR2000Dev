#!/usr/bin/env python3
"""Explicit simulation inputs -> owned taskless Pipe trial -> authoritative display feedback.

Run this delivered example with a pinned artifact. Pipe tools are an explicit read-only
optional dependency; no supplier source tree is read. No Worker/device task is created.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import sys
import time

sys.dont_write_bytecode = True


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def delivery(root, expected):
    manifest_path = root / "manifest.json"
    require(digest(manifest_path) == expected, "artifact manifest pin mismatch")
    manifest = json.loads(manifest_path.read_text())
    require(
        manifest.get("surface_control_contract") == "1.0" and manifest.get("surface_control_sdk") == "1.0.0",
        "unsupported optional Surface delivery",
    )
    for name, wanted in manifest["files_sha256"].items():
        path = root / name
        require(
            not Path(name).is_absolute()
            and ".." not in Path(name).parts
            and path.is_file()
            and not path.is_symlink()
            and path.resolve().is_relative_to(root)
            and digest(path) == wanted,
            "artifact file hash/path mismatch",
        )
    sdk = root / "surface-control-sdk-1.0.0.zip"
    require(sdk.name in manifest["files_sha256"], "Surface SDK is not in manifest")
    require("surface_control" not in sys.modules, "another Surface SDK is already loaded")
    sys.path.insert(0, str(sdk))
    module = importlib.import_module("surface_control")
    require(str(module.__file__).startswith(str(sdk) + "/"), "SDK import is not from pinned artifact")
    return module, manifest


def private_token(path):
    info = path.stat()
    require(
        path.is_file() and not path.is_symlink() and info.st_uid == os.geteuid() and not info.st_mode & 0o077,
        "token must be an owned private regular file",
    )
    return path.read_text().strip()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--pipe-tools", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--protocol", choices=("2025-11-25", "2026-07-28"), default="2025-11-25")
    args = parser.parse_args(argv)
    try:
        root = args.artifact.resolve()
        sdk, manifest = delivery(root, args.manifest_sha256)
        tools = args.pipe_tools.resolve()
        hashes = {name: digest(tools / name) for name in ("controller_trial.py", "controller_bridge.py")}
        require(
            "controller_trial" not in sys.modules and "controller_bridge" not in sys.modules,
            "Pipe tools import collision",
        )
        sys.path.insert(0, str(tools))
        trial = importlib.import_module("controller_trial")
        require(Path(trial.__file__).resolve() == tools / "controller_trial.py", "Pipe tools path mismatch")
        state = trial.owned_mock(args.state.resolve())
        client = sdk.Client(args.url, private_token(args.token_file), args.instance_id, protocol=args.protocol)
        discovery = client.discover()
        args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
        trial.save(
            args.output / "phase-provider-reset-pending.json", {"phase": "provider-reset-pending", "retry": False}
        )
        client.reset()  # Explicit new simulation context; no restart/recovery of an old arm.
        trial.save(args.output / "phase-provider-reset-completed.json", {"phase": "provider-reset-completed"})
        mapping = {name: "simulation." + name for name in ("arm", "start", "pause", "cancel")}
        cursor = sdk.CommandCursor(client, mapping)
        initial = cursor.bootstrap()
        require(not any(initial.values()), "new trial requires all-off controls")
        cfg, flash, _ = trial.prepare(trial.JsonHTTP(), state, args.output / "taskless", args.url)
        gate = trial.ActionGate()
        require(gate.sample(initial) is None, "initial snapshot cannot command")
        descriptors = discovery["profile"]["controls"]
        by_mapping = {}
        for row in descriptors:
            key = (row.get("mapping") or {}).get("id")
            if key in mapping.values() or key in {"simulation.state", "simulation.progress", "simulation.link"}:
                require(key not in by_mapping, "mapping aliases are not supported")
                by_mapping[key] = row
        observations = []
        inputs = []
        journal = trial.Journal(args.output / "platform-journal.jsonl")
        try:

            def send(name, on):
                row = by_mapping[mapping[name]]
                event = client.input(row["id"], row["encoding"], 127 if on else 0)
                inputs.append(event)
                selected = []
                for sample in cursor.poll():
                    action = gate.sample(sample["values"])
                    if action:
                        selected.append((action, sample))
                return selected

            for action, target in (("start", "running"), ("pause", "paused"), ("cancel", "canceled")):
                for name in mapping:
                    require(not send(name, False), "all-off cannot dispatch")
                require(not send("arm", True), "arm-alone cannot dispatch")
                selected = send(action, True)
                require(len(selected) == 1 and selected[0][0] == action, "single action was not selected")
                sample = selected[0][1]
                before = trial.validate_trial(flash.snapshot(), cfg)
                # Existing consumer owns target/version checks and durable reserve-before-send.
                trial.dispatch(
                    cfg,
                    flash,
                    journal,
                    action,
                    before,
                    sample["received_monotonic"],
                    before_submit=lambda: cursor.verify(sample),
                )
                after = trial.validate_trial(flash.snapshot(), cfg)
                require(
                    after["execution"]["status"] == target and after["head_event_id"] > before["head_event_id"],
                    "authoritative platform result mismatch",
                )
                values = trial.feedback_values(cfg, after, time.monotonic())
                feedback = []
                for role, value in (
                    ("state", "blink" if target == "paused" else ("off" if target == "canceled" else "on")),
                    ("progress", values[cfg["feedback"]["progress"]]),
                    ("link", "on"),
                ):
                    row = by_mapping["simulation." + role]
                    feedback.append(client.feedback(row["id"], "value" if role == "progress" else "indicator", value))
                require(not cursor.poll(), "display feedback created a business intent")
                observations.append(
                    {
                        "action": action,
                        "input_sequence": sample["sequence"],
                        "input_expected": sample["expected"],
                        "before": {
                            "execution_version": before["execution"]["version"],
                            "head_event_id": before["head_event_id"],
                        },
                        "after": {
                            "execution_id": after["execution"]["id"],
                            "status": target,
                            "execution_version": after["execution"]["version"],
                            "head_event_id": after["head_event_id"],
                            "step_status": after["steps"][0]["status"],
                            "start_gate": after["steps"][0]["start_gate"],
                        },
                        "feedback": feedback,
                    }
                )
        finally:
            journal.close()
        # Verify the optional imported dependency stayed byte-identical during the trial.
        require(
            all(digest(tools / name) == wanted for name, wanted in hashes.items()), "Pipe tools changed during trial"
        )
        report = {
            "scenario": "surface-pipe-taskless-v1",
            "passed": True,
            "scope": "simulation-inputs-real-taskless-platform",
            "physical_input_verified": False,
            "worker_or_device_execution_verified": False,
            "artifact_manifest_sha256": args.manifest_sha256,
            "artifact_source_commit": manifest["source_commit"],
            "shared_revision": manifest.get("surface_plugins_revision"),
            "protocol": args.protocol,
            "unit": state["unit"],
            "deployment_id": state["deployment_id"],
            "runtime_image_digest": state["runtime_image_digest"],
            "pipe_tool_hashes": hashes,
            "profile_id": discovery["profile"]["id"],
            "inputs": inputs,
            "observations": observations,
        }
        trial.save(args.output / "surface-pipe-report.json", report)
        print(
            json.dumps(
                {
                    "passed": True,
                    "scenario": report["scenario"],
                    "report": str(args.output / "surface-pipe-report.json"),
                }
            )
        )
        return 0
    except Exception as error:
        code = getattr(error, "code", type(error).__name__)
        # Never log exception strings returned by arbitrary transports or imported modules.
        print(
            json.dumps(
                {
                    "passed": False,
                    "code": code,
                    "retry": False,
                    "message": "Reconcile existing output before starting a new context",
                }
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
