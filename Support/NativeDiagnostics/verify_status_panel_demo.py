#!/usr/bin/env python3
"""Rehearse the packaged demo with only simulation and an explicit Debug fake device."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit


class RecordingProxy(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, url):
        endpoint = urlsplit(url)
        self.destination = (endpoint.hostname, endpoint.port)
        self.calls = []
        super().__init__(("127.0.0.1", 0), ProxyHandler)


class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(data)
        self.server.calls.append({"method": request["method"], "tool": request.get("params", {}).get("name")})
        connection = http.client.HTTPConnection(*self.server.destination, timeout=5)
        try:
            headers = dict(self.headers)
            headers["Host"] = "%s:%s" % self.server.destination
            connection.request("POST", "/mcp", data, headers)
            response = connection.getresponse()
            body = response.read()
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in ("content-length", "connection", "transfer-encoding"):
                    self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        finally:
            connection.close()


def case(artifact, profiles, output, source, mode, Client, mapping):
    output.mkdir(parents=True, exist_ok=False)
    tokens = {role: secrets.token_hex(32) for role in ("owner", "operator", "display")}
    environment = {key: value for key, value in os.environ.items() if key != "BCR_PROVIDER_TOKEN"}
    environment["PYTHONPATH"] = str(artifact / "surface-control-sdk-1.4.0.zip")
    arguments = [
        str(artifact / "BCRProviderService"),
        "--port",
        "0",
        "--surface-instance-id",
        "demo",
        "--surface-client-tokens-stdin",
        "--allow-surface-feedback",
        "--display-write-limit",
        "300",
    ]
    if source == "hardware":
        candidate = profiles / "candidates/unverified-four-role"
        selected_map = (
            profiles / "hardware-map.json" if mode == "default-refused" else candidate / "candidate-hardware-map.json"
        )
        commands = output / "TEST-ONLY-commands.json"
        commands.write_text("[]")
        environment.update(
            BCR_PROVIDER_TEST_HARDWARE="1",
            BCR_PROVIDER_TEST_HARDWARE_SCRIPT=str(commands),
            BCR_PROVIDER_TEST_HARDWARE_REPORT=str(output / "device.json"),
        )
        arguments += [
            "--source",
            "hardware",
            "--hardware-profile",
            "--hardware-output",
            "write",
            "--hardware-map",
            str(selected_map),
        ]
        if mode != "default-refused":
            arguments += ["--configuration", str(candidate / "candidate-configuration.json")]
    else:
        arguments += ["--simulation-profile"]
    with (output / "host.stderr.log").open("w") as stderr:
        provider = subprocess.Popen(
            arguments,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr,
            env=environment,
            cwd="/tmp",
            text=True,
        )
        try:
            provider.stdin.write(json.dumps(tokens))
            provider.stdin.close()
            selector = selectors.DefaultSelector()
            selector.register(provider.stdout, selectors.EVENT_READ)
            assert selector.select(10), "Provider not ready"
            ready = json.loads(provider.stdout.readline())
            if source == "hardware":
                assert ready.get("test_only_hardware_double") is True
                deadline = time.monotonic() + 5
                while not (output / "device.json").exists():
                    assert provider.poll() is None and time.monotonic() < deadline, "Fake device did not initialize"
                    time.sleep(0.005)
                assert json.loads((output / "device.json").read_text())["sent"] == [], "Headless startup sent feedback"
            owner = Client(ready["url"], tokens["owner"], "demo", accepted_sources=(source,), protocol="2026-07-28")
            owner.discover(versions=("1.4",) if source == "hardware" else ("1.3",))
            before = owner.snapshot()
            proxy = RecordingProxy(ready["url"])
            worker = threading.Thread(target=proxy.serve_forever, kwargs={"poll_interval": 0.02})
            worker.start()
            try:
                read_fd, write_fd = os.pipe()
                os.write(write_fd, tokens["display"].encode())
                os.close(write_fd)
                duration = "30" if mode == "sigint" else "3" if mode == "stale" else "1.1"
                command = [
                    sys.executable,
                    "-B",
                    "-m",
                    "surface_panel_demo",
                    "--url",
                    f"http://127.0.0.1:{proxy.server_port}/mcp",
                    "--instance-id",
                    "demo",
                    "--token-fd",
                    str(read_fd),
                    "--mapping",
                    "bcr",
                    "--source",
                    source,
                    "--hz",
                    "5",
                    "--duration",
                    duration,
                ]
                if mode == "stale":
                    command += ["--source-stops-after", ".2", "--max-age", ".3"]
                with (output / "demo.stderr.log").open("w") as demo_stderr:
                    demo = subprocess.Popen(
                        command,
                        pass_fds=(read_fd,),
                        stdout=subprocess.PIPE,
                        stderr=demo_stderr,
                        env=environment,
                        cwd="/tmp",
                        text=True,
                    )
                    os.close(read_fd)
                    try:
                        if mode == "sigint":
                            deadline = time.monotonic() + 5
                            while True:
                                page = owner.call(
                                    "surface_control_events",
                                    {
                                        "instance_id": "demo",
                                        "epoch": owner.expected["epoch"],
                                        "after_sequence": "0",
                                        "limit": 1024,
                                    },
                                )
                                fresh = any(
                                    e["control_id"] == "button.1.1" and e["value"] == "on" for e in page["events"]
                                )
                                joint_values = {
                                    e["value"] for e in page["events"] if e["control_id"] == "pushEncoder.1.1"
                                }
                                if fresh and len(joint_values) > 1:
                                    break
                                assert time.monotonic() < deadline and demo.poll() is None, (
                                    "No active demo before interrupt"
                                )
                                time.sleep(0.01)
                            demo.send_signal(signal.SIGINT)
                        stdout, _ = demo.communicate(timeout=12)
                        result = json.loads(stdout)
                        (output / "demo.stdout.json").write_text(stdout)
                    finally:
                        if demo.poll() is None:
                            demo.terminate()
                            demo.wait(timeout=5)
            finally:
                proxy.shutdown()
                proxy.server_close()
                worker.join(timeout=3)
            calls = proxy.calls
            assert {row["method"] for row in calls} <= {"initialize", "notifications/initialized", "tools/call"}
            assert {row["tool"] for row in calls if row["tool"]} <= {
                "surface_control_discover",
                "surface_control_snapshot",
                "surface_control_feedback",
            }
            (output / "rpc-tools.json").write_text(json.dumps(calls, indent=2) + "\n")
            snapshot = owner.snapshot()
            page = owner.call(
                "surface_control_events",
                {"instance_id": "demo", "epoch": owner.expected["epoch"], "after_sequence": "0", "limit": 1024},
            )
            events = page["events"]
            (output / "events.json").write_text(json.dumps(page, indent=2) + "\n")
            (output / "snapshot.json").write_text(json.dumps(snapshot, indent=2) + "\n")
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            assert snapshot["latest_input_sequence"] == before["latest_input_sequence"] == "0"
            assert snapshot["inputs"] == before["inputs"]
            assert all(
                event["kind"] == "feedback" and event["origin"] == "remote" and event["source"] == source
                for event in events
            )
            if mode == "default-refused":
                assert result["reason"] == "unsupported_feedback" and result["exit_code"] == demo.returncode == 1
                assert events == [] and not any(row["tool"] == "surface_control_feedback" for row in calls)
                assert json.loads((output / "device.json").read_text())["sent"] == []
            else:
                reason = {"normal": "complete", "stale": "source_stale", "sigint": "interrupted"}[mode]
                expected_exit = int(mode == "stale")
                assert result["reason"] == reason and result["exit_code"] == demo.returncode == expected_exit
                assert result["cleanup_failed"] == 0 and result["cleanup_attempted"] > 0
                assert len({event["writer_id"] for event in events}) == 1
                selected = next(row for row in mapping["profiles"] if row["source"] == source)
                targets = selected["targets"]
                assert {event["control_id"] for event in events} == {row["control_id"] for row in targets}
                for row in targets:
                    assert snapshot["feedback"][row["control_id"]][row["kind"]] == row["rest"]
                cleanup = events[-result["cleanup_attempted"] :]
                assert cleanup[0]["control_id"] == "button.1.1" and cleanup[0]["value"] == "off"
                assert len(events) == result["accepted"] + result["ignored"] + result["cleanup_attempted"]
                if mode == "normal":
                    assert result["frames"] >= 4
                    active = events[: -result["cleanup_attempted"]]
                    assert len({e["value"] for e in active if e["control_id"] == "pushEncoder.1.1"}) > 1
            (output / "events.json").write_text(json.dumps(page, indent=2) + "\n")
            (output / "snapshot.json").write_text(json.dumps(snapshot, indent=2) + "\n")
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            if source == "hardware":
                entries = {
                    f"{row['control']['section']}.{row['control']['row']}.{row['control']['index']}": row["midi"]
                    for row in json.loads(selected_map.read_text())["entries"]
                }
                expected_words = []
                for event in events:
                    midi = entries[event["control_id"]]
                    assert midi["kind"] == "controlChange"
                    raw = (
                        event["value"]
                        if event["encoding"] == "value"
                        else {"on": 127, "off": 0, "blink": 96}[event["value"]]
                    )
                    expected_words.append([176 + midi["channel"], midi["number"], raw])
                assert json.loads((output / "device.json").read_text())["sent"] == expected_words
                (output / "midi-proof.json").write_text(
                    json.dumps({"expected_words": expected_words, "physical_qualification": False}, indent=2) + "\n"
                )
            assert all(token not in stdout + (output / "demo.stderr.log").read_text() for token in tokens.values())
            return {"name": source + "_" + mode, "passed": True, **result}
        finally:
            provider.terminate()
            provider.wait(timeout=5)
            provider.stdout.close()
            if source == "hardware" and "expected_words" in locals():
                assert json.loads((output / "device.json").read_text())["sent"] == expected_words, (
                    "Headless exit sent feedback"
                )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--simulation-only",
        action="store_true",
        help="Run three simulation modes on a release artifact; never start hardware",
    )
    args = parser.parse_args()
    artifact, output = args.artifact.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(artifact / "surface-control-sdk-1.4.0.zip"))
    from surface_control import Client
    from surface_panel_demo import load_mapping

    mapping = load_mapping("bcr")
    profiles = artifact
    if not args.simulation_only and not (artifact / "hardware-map.json").is_file():
        profiles = output / "TEST-ONLY-profiles"
        profiles.mkdir()
        mock = json.loads(subprocess.check_output([str(artifact / "BCRProfileTool"), "--describe-mock-map"]))
        for entry in mock["entries"]:
            if entry["control"]["section"] not in ("pushEncoder", "encoder"):
                entry["visualizationOnly"] = True
        (profiles / "hardware-map.json").write_text(json.dumps(mock))
        request = profiles / "role-request.json"
        request.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "require_feedback": True,
                    "roles": {
                        "enable": "button.1.1",
                        "linear": "pushEncoder.1.1",
                        "steer": "pushEncoder.1.2",
                        "stop": "button.1.2",
                    },
                }
            )
        )
        staged = subprocess.run(
            [
                str(artifact / "BCRProfileTool"),
                "--stage-hardware-candidate",
                str(profiles / "hardware-map.json"),
                str(request),
                str(profiles / "candidates/unverified-four-role"),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        (profiles / "staging-result.json").write_text(staged.stdout)
    results = [
        case(artifact, profiles, output / (source + "-" + mode), source, mode, Client, mapping)
        for source in (("simulation",) if args.simulation_only else ("simulation", "hardware"))
        for mode in ("normal", "stale", "sigint")
    ]
    if not args.simulation_only:
        results.append(
            case(
                artifact, profiles, output / "hardware-default-refused", "hardware", "default-refused", Client, mapping
            )
        )
    report = {
        "passed_count": len(results),
        "failed_count": 0,
        "skipped_count": 0,
        "cases": results,
        "simulation_only": args.simulation_only,
        "profile_fixture": "artifact" if profiles == artifact else "generated-test-only",
        "scope": "Packaged CLI and SDK from /tmp; simulation/Debug fake device only, no CoreMIDI qualification",
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
