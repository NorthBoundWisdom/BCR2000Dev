#!/usr/bin/env python3
"""Real process/loopback acceptance using only the delivered generic SDK and executable.

No hardware or platform stack is opened. A private proxy deliberately drops one response
AFTER the provider handled a write; its request count proves there was no automatic replay.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    artifact = args.artifact.resolve()
    args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
    manifest_path = artifact / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for name, wanted in manifest["files_sha256"].items():
        path = artifact / name
        assert not Path(name).is_absolute() and ".." not in Path(name).parts
        assert path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(artifact)
        assert hashlib.sha256(path.read_bytes()).hexdigest() == wanted
    assert manifest["surface_control_contract"] == "1.1" and manifest["surface_control_sdk"] == "1.1.0"
    sdk = artifact / "surface-control-sdk-1.1.0.zip"
    sys.path.insert(0, str(sdk))
    import surface_control
    from surface_control import Client, CommandCursor, SurfaceError

    # The delivered SDK is the locked shared package source, byte for byte.
    assert surface_control.__version__ == "1.1.0" and surface_control.__file__.startswith(str(sdk) + "/")

    cases = []
    hosts = []

    def passed(name, **evidence):
        cases.append({"name": name, "passed": True, **evidence})
        print("PASS", name, flush=True)

    def rejected(operation, code):
        try:
            operation()
        except SurfaceError as error:
            assert error.code == code, (error.code, code)
        else:
            raise AssertionError("Expected a stable rejection")

    class Host:
        def __init__(self, name, *, port=0, allow=True):
            self.token = secrets.token_hex(32)
            self.error = (args.output / (name + ".stderr.log")).open("w")
            self.process = subprocess.Popen(
                [
                    str(artifact / "BCRProviderService"),
                    "--port",
                    str(port),
                    "--simulation-profile",
                    "--surface-instance-id",
                    "transport." + name.split("-")[0],
                    "--allow-device-control",
                    "--allow-simulation-control",
                    "--token-stdin",
                    *(["--allow-surface-input", "--allow-surface-feedback", "--allow-surface-reset"] if allow else []),
                ],
                cwd=args.output,
                env={**os.environ, "BCR_PROVIDER_PACKAGED": "1"},
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self.error,
            )
            hosts.append(self)
            self.process.stdin.write(self.token.encode())
            self.process.stdin.close()
            selected = selectors.DefaultSelector()
            selected.register(self.process.stdout, selectors.EVENT_READ)
            assert selected.select(15), "Provider did not announce readiness"
            self.ready = json.loads(self.process.stdout.readline())
            assert self.ready["event"] == "provider.ready"
            self.client = Client(
                self.ready["url"],
                self.token,
                "transport." + name.split("-")[0],
                provider_id=self.ready["provider_id"],
                provider_header="BCR-Provider-Id",
            )
            self.client.discover()

        def stop(self):
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.error.close()

    def state(client):
        value = client.snapshot()
        return {key: value[key] for key in ("discovery", "latest_sequence", "inputs", "feedback")}

    mapping = {name: "simulation." + name for name in ("arm", "start", "pause", "cancel")}
    try:
        first, second, denied = Host("a"), Host("b"), Host("denied", allow=False)
        for protocol in ("2025-11-25", "2026-07-28"):
            client = Client(first.ready["url"], first.token, "transport.a", protocol=protocol)
            client.discover()
            client.reset()
            assert client.input("pushEncoder.1.1", "scalar", 100)["disposition"] == "accepted"
            assert client.input("pushEncoder.1.1", "scalar", 100)["disposition"] == "ignored"
            before = client.snapshot()["inputs"]
            client.feedback("button.1.1", "indicator", "blink")
            assert client.snapshot()["inputs"] == before
            passed("raw_roundtrip_" + protocol)
        held = client.input("button.1.3", "boolean", True, hold_s=0.4)
        assert held["disposition"] == "accepted" and held["hold_deadline"] == held["time"] + 0.4
        sequence = client.latest_sequence
        renewed = client.renew("button.1.3", 0.4)
        assert renewed["hold_deadline"] > held["hold_deadline"]
        assert client.snapshot()["latest_sequence"] == sequence  # renew consumes no sequence
        time.sleep(1.2)  # no requests: the provider's own scheduler must release the button
        after = client.snapshot()
        assert after["inputs"]["button.1.3"] is False and after.get("holds", {}) == {}
        assert int(after["latest_sequence"]) == int(sequence) + 1
        page = client.call(
            "surface_control_events",
            {
                "instance_id": client.instance_id,
                "epoch": client.expected["epoch"],
                "after_sequence": sequence,
                "limit": 8,
            },
        )
        expiry = page["events"][0]
        assert expiry["reason"] == "hold_expired" and expiry["origin"] == "remote" and expiry["value"] is False
        lag = expiry["time"] - renewed["hold_deadline"]
        assert 0 <= lag < 0.5, lag  # recorded by the timer near the deadline, not by the later snapshot
        rejected(lambda: client.renew("button.1.3", 0.4), "hold_expired")
        passed("real_clock_hold_renew_and_scheduler_expiry", expiry_lag_s=round(lag, 3))
        rejected(lambda: denied.client.input("pushEncoder.1.1", "scalar", 100), "permission_denied")
        rejected(lambda: denied.client.renew("button.1.3", 0.4), "permission_denied")
        passed("permissions_default_off")
        first.client = client
        b_before = state(second.client)
        first.client.snapshot()
        first.client.reset()
        first.stop()
        assert state(second.client) == b_before
        passed("independent_provider_reset_and_stop")

        old_expected = dict(second.client.expected)
        old_sequence = second.client.latest_sequence
        old_port = int(second.ready["url"].split(":")[2].split("/")[0])
        cursor = CommandCursor(second.client, mapping)
        cursor.bootstrap()
        second.stop()
        rejected(cursor.poll, "transport_unknown")
        replacement = Host("b-replacement", port=old_port)
        rejected(cursor.poll, "recovery_required")
        rejected(
            lambda: replacement.client.call(
                "surface_control_input",
                {
                    "expected": old_expected,
                    "expected_sequence": old_sequence,
                    "control_id": "pushEncoder.1.1",
                    "encoding": "scalar",
                    "value": 127,
                },
            ),
            "stale_epoch",
        )
        passed("disconnect_revokes_cursor_and_same_port_process_replacement", port_reused=True)

        backend_port = int(replacement.ready["url"].split(":")[2].split("/")[0])
        counts = {"input": 0}

        class DropReply(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                value = json.loads(raw)
                drop = (
                    value.get("method") == "tools/call"
                    and value.get("params", {}).get("name") == "surface_control_input"
                )
                connection = http.client.HTTPConnection("127.0.0.1", backend_port, timeout=2)
                headers = {
                    key: item for key, item in self.headers.items() if key.lower() not in {"host", "content-length"}
                }
                connection.request("POST", "/mcp", raw, headers)
                response = connection.getresponse()
                body = response.read()
                if drop:
                    counts["input"] += 1
                    self.close_connection = True
                    connection.close()
                    return
                self.send_response(response.status)
                for key, item in response.getheaders():
                    if key.lower() not in {"connection", "content-length", "transfer-encoding"}:
                        self.send_header(key, item)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                connection.close()

        proxy = ThreadingHTTPServer(("127.0.0.1", 0), DropReply)
        thread = threading.Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        try:
            client = Client(
                "http://127.0.0.1:" + str(proxy.server_port) + "/mcp",
                replacement.token,
                "transport.b",
                protocol="2026-07-28",
            )
            client.discover()
            rejected(lambda: client.input("pushEncoder.1.1", "scalar", 127), "transport_unknown")
            # A later read reconciles the known accepted result; it never resends the request.
            snapshot = replacement.client.snapshot()
            assert snapshot["inputs"]["pushEncoder.1.1"] == 127 and snapshot["latest_sequence"] == "1"
            assert counts["input"] == 1
            passed("lost_response_after_acceptance_is_unknown_and_never_replayed", provider_writes=1, proxy_requests=1)
        finally:
            proxy.shutdown()
            proxy.server_close()
            thread.join(timeout=3)
        replacement.client.reset()
        stale_cursor = CommandCursor(replacement.client, mapping)
        stale_cursor.bootstrap()
        replacement.client.input("pushEncoder.1.1", "scalar", 127)
        time.sleep(2.05)
        rejected(stale_cursor.poll, "input_stale")
        rejected(stale_cursor.poll, "recovery_required")
        passed("stale_input_does_not_get_a_new_deadline")
        report = {
            "passed": True,
            "scope": "real_process_and_loopback",
            "hardware_verified": False,
            "artifact_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
            "artifact_source_commit": manifest["source_commit"],
            "shared_revision": manifest["surface_plugins_revision"],
            "cases": cases,
        }
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    finally:
        for host in hosts:
            host.stop()


if __name__ == "__main__":
    main()
