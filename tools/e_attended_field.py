#!/usr/bin/env python3
"""E attended BCR field control (plan: configs/prepare_e_attended.py).

A daemon owns one isolated provider; each step talks to it over a private local socket and the
bearer exists only in daemon memory. State lives in ignored build/e/bcr. Steps that send to the
device are marked in the plan and require the operator present. Build the provider first:
`swift build --build-path build/swiftpm`.
"""

import argparse
import atexit
import collections
import datetime
import importlib.util
import json
import os
import pathlib
import secrets
import signal
import socket
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = ROOT / "build/e/bcr"
SOCK = str(BASE / "control.sock")
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "build/seed/SurfacePlugins/clients/python"))
from surface_control import Client as SurfaceClient
from surface_control import SurfaceError

sys.path.insert(0, str(ROOT / "tools"))
from mcp_smoke import Client

BIN = ROOT / "build/swiftpm/debug/BCRProviderService"
LEARNED_MAP = pathlib.Path.home() / "Library/Application Support/BCRAgentConsole/hardware-map.json"


def save(path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)


def passive():
    spec = importlib.util.spec_from_file_location("probe", ROOT / "Support/NativeDiagnostics/midi_feedback_probe.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["probe"] = mod
    spec.loader.exec_module(mod)
    backend = mod.MacMIDI()
    ins = backend.ports(True)
    outs = backend.ports(False)
    result = {
        "inputs": [p.__dict__ for p in ins],
        "outputs": [p.__dict__ for p in outs],
        "sends_to_device": 0,
        "duration_s": 10,
        "capture_scope": "raw CoreMIDI packet bytes on selected BCR input; CC decoded separately; no queries",
    }
    try:
        port = mod.resolve(ins, None, "input")
        result["selected_input"] = port.__dict__
        result["selected_output"] = mod.resolve(outs, None, "output").__dict__
        raw = collections.deque(maxlen=8192)
        total = [0]

        def capture(chunk):
            total[0] += 1
            raw.append(chunk.hex())

        backend.raw_input = capture
        backend.open(port)
        stop = time.monotonic() + 10
        cc = 0
        while time.monotonic() < stop:
            msg = backend.events.read(0.05)
            if isinstance(msg, Exception):
                raise msg
            if msg is not None:
                cc += 1
        result.update(
            device_visible=True,
            raw_packet_count=total[0],
            cc_message_count=cc,
            cc_dropped=backend.events.dropped,
            raw_packets=list(raw),
            raw_overflow=total[0] > len(raw),
            passed=backend.events.dropped == 0 and total[0] <= len(raw),
        )
    except Exception as exc:
        result.update(device_visible=False, passed=False, error=str(exc))
    finally:
        backend.close()
    save(BASE / "passive-baseline.json", result)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["passed"] else 1


def daemon(policy, mock, surface_mode=False):
    os.umask(0o077)
    if surface_mode and not mock and not (BASE / "hardware-map.json").exists():
        raise RuntimeError("hardware 1.4 profile needs the isolated map; run prepare-map first")
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(143))
    run = BASE / ("run-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    run.mkdir(parents=True)
    token = secrets.token_hex(32)
    args = [
        str(BIN),
        "--port",
        "0",
        "--token-stdin",
        "--source",
        "mock" if mock else "hardware",
        "--data-dir",
        str(run / "data"),
        "--allow-device-control",
    ]
    if not mock:
        if (BASE / "hardware-map.json").exists():
            args += ["--hardware-map", str(BASE / "hardware-map.json")]
        if policy == "write":
            args += ["--hardware-output", "write"]
        if surface_mode:
            args += ["--hardware-profile", "--surface-instance-id", "e-field-bcr"]
        if surface_mode and policy == "write":
            args += ["--allow-surface-feedback"]
    err = (run / "provider.stderr.txt").open("w")
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True, bufsize=1)
    atexit.register(lambda: (proc.terminate(), proc.wait(timeout=8)) if proc.poll() is None else None)
    proc.stdin.write(token)
    proc.stdin.close()
    ready = proc.stdout.readline()
    if not ready:
        raise RuntimeError("Provider startup failed; see isolated provider.stderr.txt")
    ready = json.loads(ready)
    save(run / "ready.json", ready)
    client = Client(ready["url"], token)
    _, disc = client.rpc("server/discover")
    assert "result" in disc
    surface_client = (
        SurfaceClient(ready["url"], token, "e-field-bcr", accepted_sources=("hardware",)) if surface_mode else None
    )
    if surface_client:
        surface_client.discover(versions=("1.4",))
    original_rpc = client.rpc

    def pinned(*a, **kw):
        kw["extra_headers"] = {**kw.get("extra_headers", {}), "BCR-Provider-Id": ready["provider_id"]}
        return original_rpc(*a, **kw)

    client.rpc = pinned
    counts = collections.Counter()
    all_events = []
    seen = set()
    cursor = 0
    generation = None
    integrity = []
    marks = {}
    journal = (run / "events.jsonl").open("a")
    actions = (run / "actions.jsonl").open("a")

    def drain():
        nonlocal cursor, generation
        request = {"schema_version": 1, "after_sequence": cursor, "limit": 256}
        if generation:
            request["generation"] = generation
        try:
            batch = client.call("console_events", request)
        except RuntimeError:
            current = client.call("get_status")["input_generation"]
            if current == generation:
                integrity.append("event-read-error")
                raise
            generation = None
            cursor = 0
            batch = client.call("console_events", {"schema_version": 1, "limit": 256})
        if generation is None:
            if batch["earliest_sequence"] > 1:
                integrity.append("initial-event-gap")
            generation = batch["generation"]
        for e in batch["events"]:
            key = (e["generation"], e["sequence"])
            if key in seen:
                continue
            seen.add(key)
            all_events.append(e)
            counts[e["kind"]] += 1
            if e["kind"] == "control.input":
                counts["accepted_input"] += 1
            if e["kind"] == "control.input" and e["source"] == "hardware":
                counts["accepted_hardware_input"] += 1
            journal.write(json.dumps(e, ensure_ascii=False) + "\n")
            journal.flush()
            cursor = e["sequence"]

    def settle(seconds=0.4):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            drain()
            time.sleep(0.05)

    def values():
        return {x["id"]: x["value"] for x in client.call("list_parameters")}

    def status():
        return client.call("get_status")

    settle(1)
    if os.path.exists(SOCK):
        raise RuntimeError("existing socket must be stopped explicitly")
    server = socket.socket(socket.AF_UNIX)
    server.bind(SOCK)
    server.listen()
    server.settimeout(0.1)
    save(
        BASE / "current.json",
        {
            "run": str(run),
            "daemon_pid": os.getpid(),
            "provider_pid": proc.pid,
            "source": "mock" if mock else "hardware",
            "policy": policy,
            "provider_command": args,
        },
    )
    running = True

    def handle(req):
        nonlocal running, surface_client
        action = req["action"]
        out = {"action": action, "run": str(run), "source": "mock" if mock else "hardware"}
        drain()
        before = counts.copy()
        startvalues = values()
        if action == "surface-old-epoch":
            try:
                surface_client.call(
                    "surface_control_events",
                    {
                        "instance_id": "e-field-bcr",
                        "epoch": surface_client.expected["epoch"],
                        "after_sequence": "0",
                        "limit": 1024,
                    },
                )
            except SurfaceError as failure:
                out.update(passed=failure.code == "stale_epoch", code=failure.code)
            else:
                out.update(passed=False)
        elif action == "surface-button-feedback":
            try:
                surface_client.feedback("button.1.1", "indicator", "on")
            except SurfaceError as failure:
                out.update(passed=failure.code == "unsupported_feedback", code=failure.code)
            else:
                out.update(passed=False)
        elif action == "surface-status":
            out.update(snapshot=surface_client.snapshot(), passed=True)
        elif action == "surface-feedback":
            out["response"] = surface_client.feedback("pushEncoder.1.1", "value", 64)
            out["passed"] = True
        elif action == "surface-rediscover":
            surface_client = SurfaceClient(ready["url"], token, "e-field-bcr", accepted_sources=("hardware",))
            surface_client.discover(versions=("1.4",))
            out.update(snapshot=surface_client.snapshot(), passed=True)
        elif action == "status":
            out.update(
                status=status(),
                values=startvalues,
                counts=dict(counts),
                endpoints=client.call("list_midi_endpoints"),
                passed=not integrity,
            )
        elif action == "write3":
            beforedrop = status()["droppedFeedbackCount"]
            written = []
            for idx in range(1, 4):
                written.append(client.call("set_parameter", {"id": f"general.{idx}", "value": 25 + idx * 10}))
            settle(1)
            afterdrop = status()["droppedFeedbackCount"]
            sent = counts["feedback.sent"] - before["feedback.sent"]
            out.update(
                written=written,
                suppressed_before=beforedrop,
                suppressed_after=afterdrop,
                suppressed_delta=counts["feedback.suppressed"] - before["feedback.suppressed"],
                sent_delta=sent,
                passed=sent == 0 and counts["feedback.suppressed"] > before["feedback.suppressed"]
                if not mock
                else len(written) == 3,
            )
        elif action == "five":
            trials = []
            for value in (15, 30, 45, 60, 75):
                b = counts.copy()
                client.call("set_parameter", {"id": "general.1", "value": value})
                settle(1)
                trials.append(
                    {
                        "value": value,
                        "readback": client.call("get_parameter", {"id": "general.1"})["value"],
                        "sent": counts["feedback.sent"] - b["feedback.sent"],
                        "accepted_hardware_input": counts["accepted_hardware_input"] - b["accepted_hardware_input"],
                    }
                )
            out.update(
                trials=trials,
                passed=all(
                    t["value"] == t["readback"] and t["sent"] == 1 and t["accepted_hardware_input"] == 0 for t in trials
                ),
            )
        elif action == "stable":
            settle(5)
            out.update(
                sent_delta=counts["feedback.sent"] - before["feedback.sent"],
                accepted_hardware_input=counts["accepted_hardware_input"] - before["accepted_hardware_input"],
            )
            out["passed"] = out["sent_delta"] == 0 and out["accepted_hardware_input"] == 0
        elif action in ("begin-input", "begin-reconnect", "near"):
            name = req.get("name") or "near"
            marks[name] = {
                "counts": dict(counts),
                "values": values(),
                "dropped": status()["droppedFeedbackCount"],
                "event_index": len(all_events),
                "generation": generation,
            }
            if action == "near":
                out["written"] = client.call("set_parameter", {"id": "general.1", "value": 50})
                drain()
            out.update(mark=name, passed=True, awaiting_user_action=True)
        elif action in ("end-input", "end-reconnect"):
            name = req.get("name") or "near"
            mark = marks[name]
            settle(1)
            now = values()
            segment = all_events[mark["event_index"] :]
            accepted = [e for e in segment if e["kind"] == "control.input"]
            sent = [e for e in segment if e["kind"] == "feedback.sent"]
            out.update(
                mark=name,
                accepted_input=len(accepted),
                accepted_hardware_input=sum(e["source"] == "hardware" for e in accepted),
                changed_parameters=[k for k in now if mark["values"].get(k) != now[k]],
                values_before=mark["values"],
                values_after=now,
                sent_count=len(sent),
                accepted_events=accepted,
                feedback_events=sent,
                status=status(),
            )
            if action == "end-input":
                # Compare committed mapped values and emitted feedback with the same MIDI identity.
                matched = []
                for e in accepted:
                    p = e["payload"]
                    matching = [
                        f["payload"]["raw_value"]
                        for f in sent
                        if f["payload"]["midi"] == p["midi"] and f["observed_monotonic_s"] >= e["observed_monotonic_s"]
                    ]
                    matched.append(
                        {
                            "input_raw": p["raw_value"],
                            "mapped_value": p.get("mapped_value"),
                            "feedback_values": matching,
                        }
                    )
                out["input_feedback"] = matched
                out["first_input_after_latest_feedback_s"] = next(
                    (
                        e["observed_monotonic_s"]
                        - max(
                            f["observed_monotonic_s"]
                            for f in all_events
                            if f["kind"] == "feedback.sent" and f["observed_monotonic_s"] <= e["observed_monotonic_s"]
                        )
                        for e in accepted
                        if any(
                            f["kind"] == "feedback.sent" and f["observed_monotonic_s"] <= e["observed_monotonic_s"]
                            for f in all_events
                        )
                    ),
                    None,
                )
                out["target_input_count"] = sum(
                    e["payload"].get("control") == {"section": "pushEncoder", "row": 1, "index": 1} for e in accepted
                )
                out["feedback_note"] = (
                    "Same absolute input source is excluded when its physical raw value already equals feedback target; zero redundant feedback is valid (SurfaceEngine.handleInput)."
                )
                out["feedback_mismatch_count"] = sum(
                    not any(
                        e["payload"]["midi"] == f["payload"]["midi"]
                        and e["payload"]["raw_value"] == f["payload"]["raw_value"]
                        and e["observed_monotonic_s"] <= f["observed_monotonic_s"]
                        for e in accepted
                    )
                    for f in sent
                    if accepted and f["observed_monotonic_s"] >= accepted[0]["observed_monotonic_s"]
                )
                out["passed"] = (
                    out["target_input_count"] > 0
                    and (mock or out["accepted_hardware_input"] > 0)
                    and (name == "near" or "general.1" in out["changed_parameters"])
                    and out["feedback_mismatch_count"] == 0
                )
            else:
                if policy == "observe":
                    b = status()["droppedFeedbackCount"]
                    client.call("set_parameter", {"id": "general.1", "value": 65})
                    settle(0.5)
                    out.update(
                        after_reconnect_suppressed_delta=status()["droppedFeedbackCount"] - b,
                        sent_count=counts["feedback.sent"] - mark["counts"].get("feedback.sent", 0),
                    )
                    out["passed"] = (
                        out["status"]["connected"]
                        if mock
                        else out["status"]["connected"]
                        and out["sent_count"] == 0
                        and out["after_reconnect_suppressed_delta"] > 0
                    )
                else:
                    out.update(
                        passed=out["status"]["connected"],
                        classification="record",
                        note="Reconnect resync count and unexpected accepted inputs are facts; user observation required",
                    )
        elif action == "mock-input":
            if not mock:
                raise RuntimeError("synthetic input rejected by harness on hardware")
            out["response"] = client.call(
                "console_mock_input",
                {
                    "control": {"section": "pushEncoder", "row": 1, "index": 1},
                    "operation": "turn",
                    "delta": req.get("delta") or 3,
                },
            )
            settle()
            out["passed"] = True
        elif action == "stop":
            running = False
            proc.terminate()
            proc.wait(timeout=8)
            out.update(provider_exit_code=proc.returncode, provider_exited=True, passed=True)
        else:
            raise RuntimeError("unknown action")
        out["integrity_errors"] = list(integrity)
        if integrity:
            out["passed"] = False
        out["event_counts"] = dict(counts)
        out["monotonic_s"] = time.monotonic()
        actions.write(json.dumps(out, ensure_ascii=False) + "\n")
        actions.flush()
        return out

    try:
        while running:
            drain()
            try:
                conn, _ = server.accept()
            except TimeoutError:
                continue
            with conn:
                request = b""
                while not request.endswith(b"\n"):
                    part = conn.recv(65536)
                    if not part:
                        break
                    request += part
                try:
                    result = handle(json.loads(request))
                except Exception as exc:
                    result = {"passed": False, "error": str(exc)}
                conn.sendall((json.dumps(result, ensure_ascii=False) + "\n").encode())
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=8)
        journal.close()
        actions.close()
        server.close()
        os.unlink(SOCK)
        save(run / "finished.json", {"provider_exited": proc.poll() is not None, "exit_code": proc.returncode})


def request(action, name=None, delta=None):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(25)
        s.connect(SOCK)
        s.sendall((json.dumps({"action": action, "name": name, "delta": delta}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            data += s.recv(65536)
    return json.loads(data)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action")
    p.add_argument("name", nargs="?")
    p.add_argument("--surface", action="store_true")
    p.add_argument("--mock", action="store_true")
    p.add_argument("--policy", choices=["observe", "write"], default="observe")
    args = p.parse_args()
    if args.action == "prepare-map":
        # Isolated copy for the field run; the learned original is only read, never replaced.
        BASE.mkdir(parents=True, exist_ok=True)
        target = BASE / "hardware-map.json"
        source = pathlib.Path(args.name).expanduser() if args.name else LEARNED_MAP
        if not target.exists():
            data = source.read_bytes()
            json.loads(data)
            target.write_bytes(data)
            target.chmod(0o600)
            created = True
        else:
            created = False
        import hashlib

        print(
            json.dumps(
                {
                    "passed": True,
                    "copy": str(target),
                    "created": created,
                    "source": str(source),
                    "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                    "original_user_mapping_modified": False,
                }
            )
        )
        return 0
    if not BIN.exists() and args.action != "passive":
        raise RuntimeError("build the provider first: swift build --build-path build/swiftpm")
    if args.action == "role-readiness":
        result = subprocess.run(
            [
                str(BIN.parent / "BCRProfileTool"),
                "--check-hardware-roles",
                str(BASE / "hardware-map.json"),
                str(ROOT / "examples/hardware/role-readiness-request.json"),
                "--hardware-output",
                "write",
                "--allow-surface-feedback",
            ],
            capture_output=True,
            check=False,
            text=True,
        )
        print(result.stdout, end="")
        return result.returncode
    if args.action == "switch-map":
        state = json.loads((BASE / "current.json").read_text())
        old = request("status")["status"]["input_generation"]
        request("stop")
        deadline = time.monotonic() + 5
        while os.path.exists(SOCK) and time.monotonic() < deadline:
            time.sleep(0.05)
        path = BASE / "hardware-map.json"
        original = json.loads(path.read_text())
        backup = BASE / ("mapping-before-" + str(time.time_ns()) + ".json")
        save(backup, original)
        candidate = dict(original)
        candidate["entries"] = original["entries"][:-1]
        if not candidate["entries"]:
            raise RuntimeError("isolated mapping has no removable spare control")
        save(path, candidate)
        start = [sys.executable, str(__file__), "start-" + state["policy"]]
        if args.surface:
            start.append("--surface")
        subprocess.run(start, check=True, capture_output=True)
        current = request("status")["status"]["input_generation"]
        print(
            json.dumps(
                {
                    "passed": old != current,
                    "old_generation": old,
                    "new_generation": current,
                    "isolated_map_backup": str(backup),
                    "removed_controls": 1,
                    "original_user_mapping_modified": False,
                }
            )
        )
        return 0 if old != current else 1
    if args.action == "passive-worker":
        return passive()
    if args.action == "passive":
        try:
            result = subprocess.run(
                [sys.executable, str(__file__), "passive-worker"],
                capture_output=True,
                text=True,
                timeout=45,
                check=False,
            )
            print(result.stdout, end="")
            return result.returncode
        except subprocess.TimeoutExpired:
            result = {
                "device_visible": None,
                "passed": False,
                "result": "timeout",
                "timeout_s": 45,
                "sends_to_device": 0,
                "message_count": None,
                "reason": "CoreMIDI endpoint enumeration/listen did not complete in bounded worker; worker terminated; no output opened",
            }
            save(BASE / "passive-baseline.json", result)
            print(json.dumps(result))
            return 1
    if args.action == "daemon":
        daemon(args.policy, args.mock, args.surface)
        return 0
    if args.action.startswith("start-"):
        if os.path.exists(SOCK):
            raise RuntimeError("session already running; stop before starting another")
        log = (BASE / "daemon.log").open("a")
        policy = args.action.split("-", 1)[1]
        proc = subprocess.Popen(
            [sys.executable, str(__file__), "daemon", "--policy", policy]
            + (["--mock"] if args.mock else [])
            + (["--surface"] if args.surface else []),
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )
        end = time.monotonic() + 50
        while not os.path.exists(SOCK):
            if proc.poll() is not None:
                raise RuntimeError("daemon startup failed; inspect daemon.log")
            if time.monotonic() > end:
                proc.terminate()
                raise RuntimeError("daemon startup timed out")
            time.sleep(0.1)
        result = request("status")
    elif args.action == "skip-gui":
        result = {
            "passed": None,
            "result": "skip",
            "reason": "verify_connection_ui.py is explicitly fixture-only (never run against hardware); NativeUI requires BCRTest window and established isolated integration app. Existing entry does not safely drive physical consent without extending scope.",
        }
    else:
        result = request(args.action, args.name)
    print(json.dumps(result, ensure_ascii=False))
    if args.action == "stop":
        state = json.loads((BASE / "current.json").read_text())
        end = time.monotonic() + 5
        while os.path.exists(SOCK) and time.monotonic() < end:
            time.sleep(0.05)
        print(
            json.dumps(
                {
                    "daemon_socket_removed": not os.path.exists(SOCK),
                    "provider_exited": result.get("provider_exited"),
                    "daemon_pid": state["daemon_pid"],
                }
            )
        )
    return 0 if result.get("passed") is not False else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        print(json.dumps({"passed": False, "error": str(e)}))
        raise SystemExit(1)
