"""Optional Surface Control 1.0 client. Standard library only; no command retries.

Works with either host's simulation endpoint. This is separate from Provider 1.0.
Snapshots initialize a cursor; only subsequent fresh accepted input edges are intents.
"""

from __future__ import annotations

import json
import math
import re
import time
import urllib.error
import urllib.parse
import urllib.request

__version__ = "1.0.0"
PROTOCOL = "2025-11-25"
MAX_BYTES = 8 * 1024 * 1024


class SurfaceError(RuntimeError):
    def __init__(self, code, message="Surface operation rejected; no automatic retry"):
        super().__init__(message)
        self.code = code


def require(condition, code):
    if not condition:
        raise SurfaceError(code)


def cursor(value):
    require(isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]*", value) is not None, "invalid_sequence")
    require(int(value) <= 2**64 - 1, "invalid_sequence")
    return int(value)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def decode(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("nonfinite JSON")

    return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if fp is not None:
            fp.close()
        raise SurfaceError("redirect_refused")


class Client:
    """Explicit endpoint + instance pin. Transport failures leave write outcomes unknown."""

    def __init__(self, url, token, instance_id, *, timeout=2, provider_id=None, protocol=PROTOCOL):
        parsed = urllib.parse.urlsplit(url)
        require(
            parsed.scheme == "http"
            and parsed.hostname == "127.0.0.1"
            and parsed.port is not None
            and 1024 <= parsed.port <= 65535
            and parsed.path == "/mcp"
            and not parsed.query
            and not parsed.fragment
            and parsed.username is None
            and parsed.password is None,
            "invalid_url",
        )
        require(
            isinstance(token, str) and token and len(token) <= 16384 and all(33 <= ord(c) < 127 for c in token),
            "invalid_credential",
        )
        require(isinstance(instance_id, str) and instance_id and len(instance_id) <= 128, "invalid_instance")
        self.url, self.token, self.instance_id, self.timeout = url, token, instance_id, timeout
        self.provider_id = provider_id
        require(protocol in {"2025-11-25", "2026-07-28"}, "unsupported_protocol")
        self.protocol, self.session, self.connected = protocol, None, False
        self.sequence = 0
        self.expected = None
        self.latest_sequence = None
        self.server_time = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def rpc(self, method, params):
        if self.protocol == "2025-11-25" and not self.connected and method != "initialize":
            initialized = self.rpc(
                "initialize",
                {
                    "protocolVersion": self.protocol,
                    "capabilities": {},
                    "clientInfo": {"name": "surface-control-sdk", "version": __version__},
                },
            )
            require(initialized.get("protocolVersion") == self.protocol, "unsupported_protocol")
            self.connected = True
            self._initialized()
        self.sequence += 1
        if self.protocol == "2026-07-28":
            params = {
                **params,
                "_meta": {
                    "io.modelcontextprotocol/protocolVersion": self.protocol,
                    "io.modelcontextprotocol/clientCapabilities": {},
                },
            }
        raw = json.dumps(
            {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}, allow_nan=False
        ).encode()
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self.protocol,
            "Mcp-Method": method,
        }
        if self.session is not None:
            headers["Mcp-Session-Id"] = self.session
        if method == "tools/call":
            headers["Mcp-Name"] = params["name"]
        if self.provider_id is not None:
            headers["BCR-Provider-Id"] = self.provider_id
        try:
            with self.opener.open(
                urllib.request.Request(self.url, raw, headers, method="POST"), timeout=self.timeout
            ) as response:
                require(response.headers.get_content_type() == "application/json", "invalid_response")
                if self.provider_id is not None:
                    require(response.headers.get("BCR-Provider-Id") == self.provider_id, "provider_mismatch")
                session = response.headers.get("Mcp-Session-Id")
                if session is not None:
                    require(self.session is None or self.session == session, "session_changed")
                    self.session = session
                body = response.read(MAX_BYTES + 1)
                require(len(body) <= MAX_BYTES, "invalid_response")
        except urllib.error.HTTPError as error:
            code = error.code
            error.close()
            raise SurfaceError("http_" + str(code)) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise SurfaceError("transport_unknown", "Outcome may be unknown; reconcile before any new write") from None
        try:
            reply = decode(body)
        except (ValueError, UnicodeError):
            raise SurfaceError("invalid_response") from None
        require(
            isinstance(reply, dict)
            and reply.get("jsonrpc") == "2.0"
            and type(reply.get("id")) is int
            and reply["id"] == self.sequence
            and "error" not in reply
            and isinstance(reply.get("result"), dict),
            "rpc_error",
        )
        return reply["result"]

    def _initialized(self):
        raw = json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}).encode()
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self.protocol,
            "Mcp-Method": "notifications/initialized",
        }
        if self.session is not None:
            headers["Mcp-Session-Id"] = self.session
        if self.provider_id is not None:
            headers["BCR-Provider-Id"] = self.provider_id
        try:
            with self.opener.open(
                urllib.request.Request(self.url, raw, headers, method="POST"), timeout=self.timeout
            ) as response:
                require(response.status in (200, 202, 204), "initialization_failed")
                require(not response.read(MAX_BYTES + 1), "invalid_response")
        except (urllib.error.URLError, TimeoutError, OSError):
            raise SurfaceError("initialization_failed") from None

    def call(self, name, arguments=None):
        require(name.startswith("surface_control_"), "unsupported_tool")
        result = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        value = result.get("structuredContent")
        require(isinstance(value, dict) and type(result.get("isError", False)) is bool, "invalid_response")
        if result.get("isError"):
            raise SurfaceError(value.get("code", "tool_error"))
        return value

    def discover(self, profiles=("bcr2000.mock", "xtouch.compact.standard.simulation")):
        value = self.call("surface_control_discover")
        require(
            value.get("schema_version") == 1
            and value.get("contract_version") == "1.0"
            and value.get("source") == "simulation",
            "unsupported_contract",
        )
        expected, profile = value.get("expected"), value.get("profile")
        require(
            isinstance(expected, dict)
            and set(expected) == {"instance_id", "epoch", "mapping_revision", "profile_id", "profile_version"}
            and all(isinstance(v, str) and v for v in expected.values()),
            "invalid_identity",
        )
        require(expected["instance_id"] == self.instance_id, "instance_mismatch")
        require(
            isinstance(profile, dict)
            and profile.get("id") in profiles
            and profile.get("version") == "1.0"
            and profile["id"] == expected["profile_id"]
            and profile["version"] == expected["profile_version"],
            "unsupported_profile",
        )
        latest = cursor(value.get("latest_sequence"))
        require(self.latest_sequence is None or latest >= cursor(self.latest_sequence), "sequence_rollback")
        if self.expected is not None:
            require(self.expected == expected, "context_changed")
        self.expected, self.latest_sequence = expected, value["latest_sequence"]
        return value

    def snapshot(self):
        require(self.expected is not None, "not_initialized")
        value = self.call("surface_control_snapshot", {"instance_id": self.instance_id})
        require(value.get("discovery", {}).get("expected") == self.expected, "context_changed")
        require(
            value["discovery"].get("source") == "simulation" and finite(value.get("server_time")), "invalid_snapshot"
        )
        latest = cursor(value.get("latest_sequence"))
        require(self.latest_sequence is None or latest >= cursor(self.latest_sequence), "sequence_rollback")
        require(self.server_time is None or value["server_time"] >= self.server_time, "time_rollback")
        self.server_time = value["server_time"]
        require(isinstance(value.get("inputs"), dict) and isinstance(value.get("feedback"), dict), "invalid_snapshot")
        self.latest_sequence = value["latest_sequence"]
        return value

    def mutate(self, suffix, fields):
        require(self.expected is not None and self.latest_sequence is not None, "not_initialized")
        before = cursor(self.latest_sequence)
        value = self.call(
            "surface_control_" + suffix,
            {"expected": self.expected, "expected_sequence": self.latest_sequence, **fields},
        )
        if suffix == "reset":
            require(
                value.get("source") == "simulation"
                and value.get("expected", {}).get("instance_id") == self.instance_id,
                "invalid_response",
            )
            require(
                value["expected"].get("epoch") != self.expected["epoch"]
                and all(
                    value["expected"].get(key) == self.expected[key]
                    for key in ("instance_id", "profile_id", "profile_version")
                )
                and value.get("latest_sequence") == "0",
                "invalid_response",
            )
            self.expected, self.latest_sequence = value["expected"], "0"
        else:
            require(
                value.get("expected") == self.expected
                and value.get("source") == "simulation"
                and cursor(value.get("sequence")) == before + 1
                and finite(value.get("time"))
                and value.get("origin") == "remote"
                and value.get("kind") == suffix
                and value.get("disposition") in {"accepted", "ignored"}
                and all(value.get(key) == item for key, item in fields.items() if key != "kind")
                and (suffix != "feedback" or value.get("encoding") == fields["kind"]),
                "invalid_response",
            )
            self.latest_sequence = value["sequence"]
        return value

    def input(self, control_id, encoding, value):
        return self.mutate("input", {"control_id": control_id, "encoding": encoding, "value": value})

    def feedback(self, control_id, kind, value):
        return self.mutate("feedback", {"control_id": control_id, "kind": kind, "value": value})

    def reset(self):
        return self.mutate("reset", {})


class CommandCursor:
    """Explicit simulation consumer, separate from a production hardware operator bridge."""

    def __init__(self, client, mapping, *, clock=time.monotonic, max_age=2):
        require(set(mapping) == {"arm", "start", "pause", "cancel"}, "invalid_mapping")
        self.client, self.clock, self.max_age = client, clock, max_age
        self.mapping = dict(mapping)
        self.sequence = None
        self.values = {name: 0 for name in mapping}
        self.controls = {}
        self.invalidated = False
        self.last_clock = None
        self.last_event_time = None

    def bootstrap(self):
        require(self.sequence is None and not self.invalidated, "recovery_required")
        discovery = self.client.discover()
        descriptors = discovery["profile"].get("controls")
        require(isinstance(descriptors, list), "invalid_profile")
        by_target = {}
        ids = set()
        for row in descriptors:
            require(
                isinstance(row, dict) and isinstance(row.get("id"), str) and row["id"] not in ids, "invalid_profile"
            )
            ids.add(row["id"])
            mapping = row.get("mapping") or {}
            if mapping.get("kind") == "parameter":
                by_target.setdefault(mapping.get("id"), []).append(row)
        for name, target in self.mapping.items():
            rows = by_target.get(target, [])
            require(len(rows) == 1, "invalid_mapping")
            row = rows[0]
            require(
                row.get("input_kind") == "absolute"
                and row.get("encoding") == "scalar"
                and row.get("range") == {"minimum": 0, "maximum": 127, "step": 1},
                "unsupported_encoding",
            )
            self.controls[row["id"]] = name
        snapshot = self.client.snapshot()
        for control, name in self.controls.items():
            raw = snapshot["inputs"].get(control)
            require(finite(raw) and 0 <= raw <= 127 and int(raw) == raw, "unknown_input")
            self.values[name] = int(raw >= 64)
        self.sequence = cursor(snapshot["latest_sequence"])
        self.last_clock = self.clock()
        require(finite(self.last_clock), "invalid_clock")
        # Historical events are deliberately discarded; snapshots cannot authorize actions.
        return dict(self.values)

    def poll(self):
        require(self.sequence is not None and not self.invalidated, "recovery_required")
        try:
            return self._poll()
        except Exception:
            self.invalidated = True
            raise

    def _poll(self):
        expected = self.client.expected
        started = self.clock()
        require(finite(started) and (self.last_clock is None or started >= self.last_clock), "invalid_clock")
        page = self.client.call(
            "surface_control_events",
            {
                "instance_id": self.client.instance_id,
                "epoch": expected["epoch"],
                "after_sequence": str(self.sequence),
                "limit": 1024,
            },
        )
        received = self.clock()
        require(finite(received) and 0 <= received - started <= self.max_age, "input_stale")
        self.last_clock = received
        require(page.get("expected") == expected and finite(page.get("server_time")), "context_changed")
        require(self.client.server_time is None or page["server_time"] >= self.client.server_time, "time_rollback")
        self.client.server_time = page["server_time"]
        require(cursor(page.get("latest_sequence")) >= cursor(self.client.latest_sequence), "sequence_rollback")
        events = page.get("events")
        require(isinstance(events, list) and len(events) <= 1024, "invalid_events")
        samples = []
        for event in events:
            require(
                isinstance(event, dict)
                and event.get("expected") == expected
                and event.get("source") == "simulation"
                and cursor(event.get("sequence")) == self.sequence + 1,
                "event_gap",
            )
            require(
                event.get("kind") in {"input", "feedback", "readback"}
                and event.get("disposition") in {"accepted", "ignored"}
                and event.get("origin") in {"interface", "remote"}
                and finite(event.get("time"))
                and (self.last_event_time is None or event["time"] >= self.last_event_time)
                and event["time"] <= page["server_time"],
                "invalid_event",
            )
            if event["disposition"] == "ignored":
                require(isinstance(event.get("reason"), str) and 0 < len(event["reason"]) <= 128, "invalid_event")
            self.last_event_time = event["time"]
            self.sequence += 1
            if event.get("kind") != "input" or event.get("disposition") != "accepted":
                continue
            require(event.get("origin") in {"interface", "remote"}, "invalid_source")
            name = self.controls.get(event.get("control_id"))
            if name is None:
                continue
            raw = event.get("value")
            require(
                event.get("encoding") == "scalar" and finite(raw) and int(raw) == raw and 0 <= raw <= 127,
                "invalid_input",
            )
            require(finite(event.get("time")), "invalid_time")
            age = page["server_time"] - event["time"]
            require(0 <= age <= self.max_age, "input_stale")
            value = int(raw >= 64)
            if value == self.values[name]:
                continue  # Neither identical raw samples nor same-side dial ticks renew an old intent.
            self.values[name] = value
            samples.append(
                {
                    "values": dict(self.values),
                    "expected": dict(expected),
                    "sequence": str(self.sequence),
                    "source": "simulation",
                    "origin": event["origin"],
                    "received_monotonic": received,
                    "expires_monotonic": started + self.max_age - age,
                }
            )
        latest = cursor(page.get("latest_sequence"))
        require(latest >= self.sequence and (events or latest == self.sequence), "event_gap")
        self.client.latest_sequence = str(latest)
        return samples

    def verify(self, sample):
        require(not self.invalidated, "recovery_required")
        try:
            return self._verify(sample)
        except Exception:
            self.invalidated = True
            raise

    def _verify(self, sample):
        require(
            not self.invalidated
            and sample.get("expected") == self.client.expected
            and sample.get("values") == self.values
            and sample.get("sequence") == str(self.sequence),
            "input_superseded",
        )
        now = self.clock()
        require(
            finite(now)
            and sample["received_monotonic"] <= now <= sample["expires_monotonic"]
            and (self.last_clock is None or now >= self.last_clock),
            "input_stale",
        )
        self.last_clock = now
        snapshot = self.client.snapshot()
        require(cursor(snapshot["latest_sequence"]) == self.sequence, "input_superseded")
        for control, name in self.controls.items():
            raw = snapshot["inputs"].get(control)
            require(finite(raw) and int(raw >= 64) == self.values[name], "input_superseded")
        now = self.clock()
        require(
            finite(now)
            and sample["received_monotonic"] <= now <= sample["expires_monotonic"]
            and (self.last_clock is None or now >= self.last_clock),
            "input_stale",
        )
        self.last_clock = now


__all__ = ["Client", "CommandCursor", "SurfaceError", "__version__"]
