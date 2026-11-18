"""Temporary input-only scheduler comparison, retained until O-4 cutover."""

from __future__ import annotations

from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time
import uuid

TRACE_ENV = "BCR_J4_SHADOW_ROOT"
REPLAY_ENV = "BCR_J4_REPLAY_ARCHIVE"
REPLAY_CASE = "BCRAgentCoreTests.J4SchedulerArchiveReplayTests/testReplayRecordedNativeSchedulerInputs"
SESSION_REPLAY_CASE = "BCRAgentCoreTests.J4SessionSchedulerArchiveReplayTests/testReplayRecordedSessionInputs"


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeError("Duplicate J4 raw JSON field")
        result[key] = value
    return result


def _finite_json_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise RuntimeError("Nonfinite J4 JSON numeric overflow")
    return value


def _finite_json_int(text):
    value = int(text)
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite:
        raise RuntimeError("Nonfinite J4 JSON integer overflow")
    return value


def _load(line):
    return json.loads(
        line,
        parse_float=_finite_json_float,
        parse_int=_finite_json_int,
        object_pairs_hook=_object,
        parse_constant=lambda _: (_ for _ in ()).throw(RuntimeError("Nonfinite J4 JSON")),
    )


def _validate_session_row(row):
    """All original Session envelope checks, applied to the same strictly parsed row."""
    expected = {"schema_version", "owner", "ordinal", "operation", "arguments", "context"}
    if type(row) is not dict or row.keys() != expected:
        raise RuntimeError("Invalid Session native input top-level fields")
    if type(row["schema_version"]) is not int or row["schema_version"] != 1:
        raise RuntimeError("Invalid Session native input schema version/type")
    if type(row["owner"]) is not str or not row["owner"] or type(row["ordinal"]) is not str:
        raise RuntimeError("Invalid Session native input identity")
    ordinal = row["ordinal"]
    if not re.fullmatch(r"[1-9][0-9]*", ordinal) or int(ordinal) > 2**64 - 1:
        raise RuntimeError("Invalid Session native input ordinal")
    if (
        type(row["operation"]) is not str
        or row["operation"]
        not in {
            "attach_scheduler",
            "clear_queue",
            "message_intent",
            "dispatch_environment",
            "actual_boundary_result",
            "admission_completed",
        }
        or type(row["arguments"]) is not dict
        or type(row["context"]) is not dict
    ):
        raise RuntimeError("Invalid Session native input operation/objects")


def validate_session_input(path: Path):
    """Validate the actual six-field native writer envelope before any lossy Foundation parse."""
    count = 0
    with path.open() as source:
        for line in source:
            _validate_session_row(_load(line))
            count += 1
    return count


def _source_cursor(row):
    if type(row.get("owner")) is not str or not row["owner"] or type(row.get("ordinal")) is not str:
        raise RuntimeError("Invalid original source identity")
    ordinal = row["ordinal"]
    if not re.fullmatch(r"[1-9][0-9]*", ordinal) or int(ordinal) > 2**64 - 1:
        raise RuntimeError("Invalid original source cursor")
    return row["owner"], int(ordinal)


def _process_source_paths(session):
    match = re.fullmatch(r"session-input-([0-9]+)\.jsonl", session.name)
    if not match:
        raise RuntimeError("Original process Session filename is invalid")
    return {
        family: session.with_name(family + "-" + match[1] + ".jsonl")
        for family in ("session-input", "scheduler-input", "session-native", "scheduler-native")
    }


def validate_process_inputs(session: Path):
    # Recorder.sessionOrdinals and Recorder.ordinals are separate per-owner namespaces;
    # Recorder.causalOrdinal is one shared cursor across these two input families only.
    paths = _process_source_paths(session)
    causal = set()
    summary = {}
    for family in ("session-input", "scheduler-input"):
        cursors, counts, total, observation_only, last_causal = {}, {}, 0, 0, 0
        with paths[family].open() as source:
            for line in source:
                row = _load(line)
                if family == "session-input":
                    _validate_session_row(row)
                if type(row) is not dict or set(row) != {
                    "schema_version",
                    "owner",
                    "ordinal",
                    "operation",
                    "arguments",
                    "context",
                }:
                    raise RuntimeError("Original input envelope fields")
                if type(row["schema_version"]) is not int or row["schema_version"] != 1:
                    raise RuntimeError("Original input schema version/type")
                owner, ordinal = _source_cursor(row)
                if ordinal != cursors.get(owner, 0) + 1:
                    raise RuntimeError("Original " + family + " owner cursor gap/duplicate")
                cursors[owner] = ordinal
                context = row["context"]
                raw = context.get("causal_ordinal") if type(context) is dict else None
                if (
                    type(raw) is not str
                    or not re.fullmatch(r"[1-9][0-9]*", raw)
                    or int(raw) > 2**64 - 1
                    or int(raw) in causal
                ):
                    raise RuntimeError("Original causal cursor duplicate/type")
                if int(raw) <= last_causal:
                    raise RuntimeError("Original family causal cursor reordered")
                last_causal = int(raw)
                causal.add(int(raw))
                operation = row["operation"]
                if type(operation) is not str:
                    raise RuntimeError("Original operation type")
                counts[operation] = counts.get(operation, 0) + 1
                if family == "session-input" and (
                    operation == "attach_scheduler"
                    or operation == "clear_queue"
                    and row["arguments"].get("scheduler_owner") is not None
                ):
                    observation_only += 1
                total += 1
        summary[family] = {
            "owners": len(cursors),
            "records": total,
            "operations": counts,
            "observation_only_records": observation_only,
        }
    if causal != set(range(1, len(causal) + 1)):
        raise RuntimeError("Original shared causal cursor gap")
    summary["shared_causal_records"] = len(causal)
    return summary


def validate_process_outputs(session: Path):
    # Called only after all candidate evolution; outputs are integrity references, never inputs/state.
    paths = _process_source_paths(session)
    summary = {}
    for input_family, output_family in (("session-input", "session-native"), ("scheduler-input", "scheduler-native")):
        expected = set()
        with paths[input_family].open() as source:
            for line in source:
                row = _load(line)
                if input_family == "scheduler-input" or row["operation"] == "message_intent":
                    key = _source_cursor(row)
                    if key in expected:
                        raise RuntimeError("Duplicate original input for output association")
                    expected.add(key)
        seen = set()
        with paths[output_family].open() as source:
            for line in source:
                row = _load(line)
                if type(row) is not dict or set(row) != {"schema_version", "owner", "ordinal", "output"}:
                    raise RuntimeError("Original native result envelope fields")
                if (
                    type(row["schema_version"]) is not int
                    or row["schema_version"] != 1
                    or type(row["output"]) is not dict
                ):
                    raise RuntimeError("Original native result schema/type")
                key = _source_cursor(row)
                if key in seen or key not in expected:
                    raise RuntimeError("Duplicate/unassociated original native result")
                if output_family == "session-native" and (
                    set(row["output"]) != {"disposition"}
                    or row["output"]["disposition"] not in ("send", "enqueue", "suppressed_observe")
                ):
                    raise RuntimeError("Original disposition fields/value")
                if output_family == "scheduler-native" and set(row["output"]) != {
                    "pending",
                    "drained",
                    "tokens",
                    "refill",
                    "retry",
                    "removed_keys",
                    "replaced_keys",
                }:
                    raise RuntimeError("Original scheduler native output fields")
                seen.add(key)
        if seen != expected:
            raise RuntimeError("Missing original native output/disposition coverage")
        summary[output_family] = {"expected": len(expected), "unique_results": len(seen), "complete": True}
    return summary


@contextmanager
def capture(root: Path, directory: Path):
    manifest = (root / "Package.swift").read_text()
    if not re.search(r'\.product\(\s*name:\s*"SurfaceFeedbackPlanning"', manifest):
        yield None
        return
    required = [
        "Sources/BCRSurfaceDomain/FeedbackJ4Trace.swift",
        "Sources/BCRSurfaceDomain/FeedbackRuntime.swift",
        "Tests/BCRAgentCoreTests/J4SchedulerArchiveReplayTests.swift",
        "Tests/BCRAgentCoreTests/J4SessionSchedulerArchiveReplayTests.swift",
    ]
    if any(not (root / path).is_file() for path in required):
        raise RuntimeError(
            "J4 native verification requires actual hooks, strict live gate and Tests-only candidate executor"
        )
    previous = os.environ.get(TRACE_ENV)
    trace = Path(previous).resolve() if previous else directory / "feedback-runtime"
    trace.mkdir(parents=True, exist_ok=True)
    if any(trace.iterdir()):
        raise RuntimeError("J4 verification refuses reused evidence")
    marker = {
        "run": str(uuid.uuid4()),
        "base": "Core plan/preflight/receipt primary; native scheduler",
        "trace": str(trace),
    }
    (trace / "run-marker.json").write_text(json.dumps(marker) + "\n")
    (directory / "feedback-verification.json").write_text(json.dumps(marker) + "\n")
    os.environ[TRACE_ENV] = str(trace)
    try:
        yield trace
    finally:
        if previous is None:
            os.environ.pop(TRACE_ENV, None)
        else:
            os.environ[TRACE_ENV] = previous


def measured_child(argv, *, root, environment, log_path, timeout, memory_limit_kib=2 * 1024 * 1024):
    """Bound this owned diagnostic worker, preserving real elapsed/peak; never touch another process."""
    started = time.monotonic()
    peak = 0
    stopped = None
    with log_path.open("w") as log:
        process = subprocess.Popen(argv, cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
        log_path.with_suffix(".started.json").write_text(
            json.dumps({"pid": process.pid, "argv": argv, "wall_started_unix": time.time()}, indent=2) + "\n"
        )
        while process.poll() is None:
            sample = subprocess.run(["ps", "-p", str(process.pid), "-o", "rss="], capture_output=True, text=True)
            if sample.stdout.strip().isdigit():
                peak = max(peak, int(sample.stdout.strip()))
            if peak > memory_limit_kib:
                stopped = "diagnostic_worker_memory_limit"
                process.kill()
                break
            if time.monotonic() - started > timeout:
                stopped = "original_native_deadline"
                process.kill()
                break
            time.sleep(0.05)
        code = process.wait()
    report = {
        "pid": process.pid,
        "argv": argv,
        "exit_code": code,
        "wall_seconds": time.monotonic() - started,
        "peak_rss_kib": peak,
        "memory_limit_kib": memory_limit_kib,
        "stopped_reason": stopped,
    }
    log_path.with_suffix(".resource.json").write_text(json.dumps(report, indent=2) + "\n")
    if stopped:
        raise RuntimeError("J4 owned diagnostic worker stopped: " + stopped)
    return report


def _bundle(binary: Path, module: str):
    bundle = binary / (module + ".xctest")
    if bundle.is_dir():
        return bundle
    candidates = list(binary.glob("*PackageTests.xctest"))
    if len(candidates) != 1:
        raise RuntimeError("Missing J4 precompiled test bundle")
    return candidates[0]


def verify(root: Path, directory: Path, trace: Path | None, remaining: float):
    if trace is None:
        return
    began = time.monotonic()
    if remaining <= 0:
        raise RuntimeError("J4 verification exceeded original native deadline")
    marker = _load((directory / "feedback-verification.json").read_text())
    if marker != _load((trace / "run-marker.json").read_text()):
        raise RuntimeError("J4 evidence marker does not belong to this run")
    proof = {"scope": "temporary scheduler input-only current/cold comparison"}
    # Pure scheduler worker processes still have an empty Session file; their shared causal
    # cursor must not evade source integrity simply because there is no Session intent.
    empty_session_sources = [path for path in trace.glob("session-input-*.jsonl") if not path.stat().st_size]
    proof["scheduler_only_source_inputs"] = {path.name: validate_process_inputs(path) for path in empty_session_sources}
    binary = Path((directory / "binary-path.log").read_text().strip())
    executable = (directory / "xctest-path.log").read_text().strip()
    environment = os.environ.copy()
    for key in (TRACE_ENV, "BCR_J3_SHADOW_ROOT", "BCR_J4_NEGATIVE_PHASE"):
        environment.pop(key, None)
    environment[REPLAY_ENV] = str(trace)
    argv = [executable, "-XCTest", REPLAY_CASE, str(_bundle(binary, "BCRAgentCoreTests"))]
    with (directory / "feedback-candidate-replay.log").open("w") as log:
        result = subprocess.run(
            argv,
            cwd=root,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=max(0.001, remaining - (time.monotonic() - began)),
        )
    if result.returncode:
        raise RuntimeError("J4 input-only bucket replay failed; preserve complete report for classification")
    report = _load((trace / "bucket-candidate/report.json").read_text())
    if (
        report.get("input_operations", 0) <= 0
        or report.get("input_only_cold_replay") is not True
        or report.get("native_used_as_state_seed") is not False
    ):
        raise RuntimeError("J4 candidate proof missing or incomplete")
    session_files = sorted(
        (path for path in trace.glob("session-input-*.jsonl") if path.stat().st_size),
        key=lambda path: (-path.stat().st_size, path.name),
    )
    if not session_files:
        raise RuntimeError("J4 original Session input family is missing")
    session_command = [executable, "-XCTest", SESSION_REPLAY_CASE, str(_bundle(binary, "BCRAgentCoreTests"))]
    workers = min(4, max(1, os.cpu_count() or 1))

    def replay_process(path):
        process = path.stem.removeprefix("session-input-")
        env = environment.copy()
        env["BCR_J4_REPLAY_PROCESS"] = process
        resource = measured_child(
            session_command,
            root=root,
            environment=env,
            log_path=directory / ("feedback-session-replay-" + process + ".log"),
            timeout=max(0.001, remaining - (time.monotonic() - began)),
        )
        if resource["exit_code"]:
            raise RuntimeError("J4 own-item Session replay/binding failed for original process " + process)
        report = _load((trace / ("session-candidate-" + process) / "report.json").read_text())
        processes = report.get("processes", [])
        if (
            len(processes) != 1
            or processes[0].get("source") != path.name
            or processes[0].get("input_only_cold_replay") is not True
            or processes[0].get("native_output_used_as_state") is not False
        ):
            raise RuntimeError("J4 Session replay omitted/misattributed original process " + process)
        processes[0]["resource"] = resource
        return processes[0]

    with ThreadPoolExecutor(max_workers=workers) as executor:
        processes = list(executor.map(replay_process, session_files))
    if (
        sum(item.get("own_gates", 0) for item in processes) <= 0
        or sum(item.get("actual_admission_receipts", 0) for item in processes) <= 0
    ):
        raise RuntimeError("J4 Session own-item gate/receipt proof missing")
    proof["scheduler_only_source_outputs"] = {
        path.name: validate_process_outputs(path) for path in empty_session_sources
    }
    session_report = {
        "scope": "own direct/queue proposal, fresh Session gates, admission-call receipts; physical layer unknown",
        "workers": workers,
        "processes": processes,
    }
    (directory / "feedback-session-replay-report.json").write_text(json.dumps(session_report, indent=2) + "\n")
    proof.update(
        {
            "bucket_candidate": report,
            "scheduler_full_direct_gate_receipt_candidate": session_report,
            "remaining_original_deadline_s": remaining - (time.monotonic() - began),
        }
    )
    (directory / "feedback-shadow-proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(
        "Verified temporary scheduler input-only current/cold replay: " + str(directory / "feedback-shadow-proof.json"),
        flush=True,
    )


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Validate original native Session trace envelopes")
    options = parser.add_mutually_exclusive_group(required=True)
    options.add_argument("--validate-session-input", type=Path)
    options.add_argument("--validate-process-inputs", type=Path)
    options.add_argument("--validate-process-outputs", type=Path)
    args = parser.parse_args()
    if args.validate_process_inputs:
        print(json.dumps(validate_process_inputs(args.validate_process_inputs), sort_keys=True))
    elif args.validate_process_outputs:
        print(json.dumps(validate_process_outputs(args.validate_process_outputs), sort_keys=True))
    else:
        validate_session_input(args.validate_session_input)
