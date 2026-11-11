#!/usr/bin/env python3
"""Probe public shared MCP tools on an isolated loopback host; no product imports or hardware."""

from __future__ import annotations

import argparse
import json
import os
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        raise RuntimeError("Redirects are not allowed")


class RPC:
    def __init__(self, url, token, legacy):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.username or parsed.password:
            raise RuntimeError("Only explicit IPv4 loopback HTTP endpoints are accepted")
        self.url, self.token, self.legacy = url, token, legacy
        self.sequence, self.session = 0, None
        self.version = "2025-11-25" if legacy else "2026-07-28"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method, params=None, notification=False):
        params = dict(params or {})
        if not self.legacy:
            params["_meta"] = {
                "io.modelcontextprotocol/protocolVersion": self.version,
                "io.modelcontextprotocol/clientCapabilities": {},
                "io.modelcontextprotocol/clientInfo": {"name": "shared-contract-probe", "version": "1.0"},
            }
        self.sequence += 1
        value = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            value["id"] = self.sequence
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self.version,
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        if not self.legacy:
            headers["Mcp-Method"] = method
            if method == "tools/call":
                headers["Mcp-Name"] = params["name"]
        request = urllib.request.Request(self.url, json.dumps(value, allow_nan=False).encode(), headers, method="POST")
        with self.opener.open(request, timeout=10) as response:
            self.session = response.headers.get("Mcp-Session-Id") or self.session
            body = response.read()
            reply = json.loads(body) if body else {}
        if "error" in reply:
            raise RuntimeError(f"JSON-RPC {method} failed")
        return reply.get("result", {})

    def start(self):
        if self.legacy:
            self.request(
                "initialize",
                {
                    "protocolVersion": self.version,
                    "capabilities": {},
                    "clientInfo": {"name": "shared-contract-probe", "version": "1.0"},
                },
            )
            self.request("notifications/initialized", notification=True)
        else:
            self.request("server/discover")
        self.tools = {
            tool["name"]: tool for tool in self.request("tools/list")["tools"] if tool["name"].startswith("surface_")
        }
        assert {"surface_capabilities", "surface_events"} <= self.tools.keys()
        assert all(tool["outputSchema"].get("type") == "object" for tool in self.tools.values())

    def call(self, name, arguments=None, error=None):
        reply = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        content = reply["structuredContent"]
        assert content == json.loads(reply["content"][0]["text"]), "Raw JSON text and structuredContent differ"
        assert bool(reply.get("isError")) == bool(error), f"Unexpected tool success/error for {name}"
        if error:
            assert content.get("code") == error and isinstance(content.get("fields"), dict), (
                f"Unexpected error code for {name}"
            )
        else:
            validate(content, self.tools[name]["outputSchema"])
        return content

    def close(self):
        if self.session:
            request = urllib.request.Request(
                self.url,
                headers={
                    "Authorization": "Bearer " + self.token,
                    "MCP-Protocol-Version": self.version,
                    "Mcp-Session-Id": self.session,
                },
                method="DELETE",
            )
            with self.opener.open(request, timeout=10) as response:
                assert response.status == 200


def validate(value, schema):
    """Independent validator for the explicit JSON Schema vocabulary used by shared outputs."""
    for combinator in ("anyOf", "oneOf"):
        if combinator in schema:
            matches = 0
            for candidate in schema[combinator]:
                try:
                    validate(value, candidate)
                    matches += 1
                except AssertionError:
                    pass
            assert matches == 1 if combinator == "oneOf" else matches >= 1
    kind = schema.get("type")
    if kind:
        checks = {
            "object": isinstance(value, dict),
            "array": isinstance(value, list),
            "number": type(value) in (int, float),
            "integer": type(value) is int,
            "string": isinstance(value, str),
            "boolean": type(value) is bool,
            "null": value is None,
        }
        assert checks[kind], "Schema type mismatch"
    if isinstance(value, dict):
        assert set(schema.get("required", [])) <= value.keys(), "Required output field missing"
        fields = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            assert value.keys() <= fields.keys(), "Undeclared output field"
        for key, child in value.items():
            if key in fields:
                validate(child, fields[key])
    if isinstance(value, list) and "items" in schema:
        for child in value:
            validate(child, schema["items"])
    if isinstance(value, str):
        assert len(value) >= schema.get("minLength", 0)


def probe(rpc):
    rpc.start()
    capabilities = rpc.call("surface_capabilities")
    instances = {item["manifest"]["id"]: item["instance_id"] for item in capabilities["instances"]}
    for item in capabilities["instances"]:
        if item["manifest"]["id"] in {"robot", "chassis"}:
            assert item["manifest"]["source"] == "simulation", "Refusing non-simulation motion capability"
    if "agent" in instances:
        rpc.call("surface_agent_snapshot", {"instance_id": instances["agent"]})
    if "output" in instances:
        arguments = {"instance_id": instances["output"]}
        rpc.call("surface_output_snapshot", arguments)
        rpc.call("surface_output_enable", arguments, error="permissionDenied")
        rpc.call("surface_output_disable", arguments)
    for kind, initial_key, initial in (("robot", "joints_rad", [0] * 6), ("chassis", "pose_m_rad", [0] * 3)):
        if kind not in instances:
            continue
        base = {"instance_id": instances[kind]}
        state = rpc.call(f"surface_{kind}_snapshot", base)
        rpc.call(
            f"surface_{kind}_initialize", {**base, "generation": state["metadata"]["generation"], initial_key: initial}
        )
        state = rpc.call(f"surface_{kind}_snapshot", base)
        grant = rpc.call(
            f"surface_{kind}_acquire",
            {**base, "generation": state["metadata"]["generation"], "owner": "probe", "ttl_s": 5},
        )
        proof = {**base, "generation": grant["generation"], "control_token": grant["control_token"]}
        rpc.call(f"surface_{kind}_enable", {**proof, "sequence": 1})
        if kind == "robot":
            rpc.call(
                "surface_robot_move",
                {
                    **proof,
                    "sequence": 2,
                    "target_joints_rad": [0.01, 0, 0, 0, 0, 0],
                    "duration_s": 0.5,
                    "valid_for_s": 1,
                },
            )
        else:
            rpc.call(
                "surface_chassis_drive",
                {**proof, "sequence": 2, "speed_m_s": 0.1, "steering_angle_rad": 0.1, "valid_for_s": 1},
            )
        rpc.call(f"surface_{kind}_advance", {**base, "dt_s": 0.1})
        rpc.call(f"surface_{kind}_stop", {**proof, "sequence": 3})
        rpc.call(f"surface_{kind}_advance", {**base, "dt_s": 0.1})
        state = rpc.call(f"surface_{kind}_snapshot", base)
        assert state["stopped"] and grant["control_token"] not in json.dumps(state)
        trace = rpc.call(f"surface_{kind}_trace", base)
        assert isinstance(trace["samples"], list)
        rpc.call(f"surface_{kind}_initialize", {}, error="unsupported")
    # A gap requires fresh snapshots followed by re-anchoring at the high-water mark.
    first = rpc.call("surface_events", {"epoch": "bootstrap", "after": "0", "limit": 1})
    for kind, identifier in instances.items():
        rpc.call(f"surface_{kind}_snapshot", {"instance_id": identifier})
    epoch, cursor, observed = first["epoch"], str(first["latestSequence"]), []
    # Add three safe operations after the new anchor, then deliberately page one at a
    # time. This catches clients that skip pending pages by using latestSequence.
    if "output" in instances:
        for _ in range(3):
            rpc.call("surface_output_disable", {"instance_id": instances["output"]})
    elif "robot" in instances or "chassis" in instances:
        kind = "robot" if "robot" in instances else "chassis"
        for _ in range(3):
            rpc.call(f"surface_{kind}_advance", {"instance_id": instances[kind], "dt_s": 0.01})
    for _ in range(4096):
        page = rpc.call("surface_events", {"epoch": epoch, "after": cursor, "limit": 1})
        assert not page["gap"], "Unexpected event gap in isolated short probe"
        if not page["events"]:
            break
        observed += [event["sequence"] for event in page["events"]]
        cursor = str(page["events"][-1]["sequence"])
        if int(cursor) >= page["latestSequence"]:
            break
    if instances:
        assert len(observed) >= 3, "Pagination skipped committed events"
    assert observed == sorted(set(observed)), "Events duplicated or reordered"
    print(
        f"MCP {rpc.version}: shared raw object schemas, scoped authority, snapshots, control and event paging passed ({len(rpc.tools)} tools)."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.environ.get("BCR_MCP_URL", "http://127.0.0.1:8787/mcp"))
    args = parser.parse_args()
    token = os.environ.get("BCR_MCP_TOKEN")
    if not token:
        parser.error("Set BCR_MCP_TOKEN; credentials are never accepted on argv or printed")
    for legacy in (False, True):
        rpc = RPC(args.url, token, legacy)
        try:
            probe(rpc)
        finally:
            rpc.close()


if __name__ == "__main__":
    main()
