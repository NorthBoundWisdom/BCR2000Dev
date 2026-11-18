#!/usr/bin/env python3
"""Read-only MCP acceptance probe; --write requires authenticated Mock source and restores values."""

import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.request

CURRENT = "2026-07-28"
LEGACY = "2025-11-25"


class Client:
    def __init__(self, url, token, legacy=False):
        self.url, self.token, self.legacy = url, token, legacy
        self.session = None
        self.request_id = 0
        self.source = None
        self.require_mock = False

    def rpc(self, method, params=None, notification=False, token=None, extra_headers=None, *, timeout=5):
        self.request_id += 1
        params = dict(params or {})
        version = LEGACY if self.legacy else CURRENT
        if not self.legacy:
            params["_meta"] = {
                "io.modelcontextprotocol/protocolVersion": CURRENT,
                "io.modelcontextprotocol/clientCapabilities": {},
                "io.modelcontextprotocol/clientInfo": {"name": "bcr-generic-smoke", "version": "1.0"},
            }
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            body["id"] = self.request_id
        headers = {
            "Authorization": "Bearer " + (self.token if token is None else token),
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": version,
        }
        if not self.legacy:
            headers["Mcp-Method"] = method
            if method == "tools/call":
                headers["Mcp-Name"] = params["name"]
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        headers.update(extra_headers or {})
        if self.require_mock:
            headers["X-BCR-Require-Source"] = "mock"
        request = urllib.request.Request(self.url, json.dumps(body, allow_nan=False).encode(), headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                self.source = response.headers.get("X-BCR-Source")
                if response.headers.get("Mcp-Session-Id"):
                    self.session = response.headers["Mcp-Session-Id"]
                data = response.read()
                return response.status, json.loads(data) if data else {}
        except urllib.error.HTTPError as exc:
            self.source = exc.headers.get("X-BCR-Source")
            data = exc.read()
            return exc.code, json.loads(data) if data else {}

    def call(self, name, args=None, expect_error=False):
        status, reply = self.rpc("tools/call", {"name": name, "arguments": args or {}})
        if status != 200 or "error" in reply:
            raise RuntimeError(f"{name}: HTTP {status}, JSON-RPC error")
        result = reply["result"]
        if bool(result.get("isError")) != expect_error:
            raise RuntimeError(f"{name}: unexpected tool success/error")
        return result["structuredContent"]["data"]

    def parameter_definition(self, identifier):
        status, response = self.rpc("tools/list")
        if status != 200:
            raise RuntimeError("tool schema discovery failed")
        tool = next(item for item in response["result"]["tools"] if item["name"] == "update_parameter")
        properties = tool["inputSchema"]["properties"]["definition"]["properties"]
        info = self.call("get_parameter", {"id": identifier})
        return {key: value for key, value in info.items() if key in properties}

    def close(self):
        if not self.session:
            return
        request = urllib.request.Request(
            self.url,
            headers={
                "Authorization": "Bearer " + self.token,
                "MCP-Protocol-Version": LEGACY,
                "Mcp-Session-Id": self.session,
            },
            method="DELETE",
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            if response.status != 200:
                raise RuntimeError("session cleanup failed")
        self.session = None


def probe(client, parameter, value, write=False):
    try:
        if client.legacy:
            status, reply = client.rpc(
                "initialize",
                {
                    "protocolVersion": LEGACY,
                    "capabilities": {},
                    "clientInfo": {"name": "bcr-generic-smoke", "version": "1.0"},
                },
            )
            if status != 200 or reply.get("result", {}).get("protocolVersion") != LEGACY or not client.session:
                raise RuntimeError("legacy initialization failed")
            if client.rpc("notifications/initialized", notification=True)[0] != 202:
                raise RuntimeError("initialized notification failed")
        else:
            status, reply = client.rpc("server/discover")
            if status != 200 or CURRENT not in reply.get("result", {}).get("supportedVersions", []):
                raise RuntimeError("modern capability discovery failed")
        status, reply = client.rpc("tools/list")
        names = {tool["name"] for tool in reply.get("result", {}).get("tools", [])}
        if status != 200 or not {"set_parameter", "get_parameter", "set_parameters"}.issubset(names):
            raise RuntimeError("tool discovery failed")
        original = client.call("get_parameter", {"id": parameter})["value"]
        if write:
            if client.source != "mock":
                raise RuntimeError(
                    "write refused: authenticated Mock source required; hardware or unknown source is read-only"
                )
            client.require_mock = True
            try:
                written = client.call("set_parameter", {"id": parameter, "value": value})
                current = client.call("get_parameter", {"id": parameter})["value"]
                if not math.isclose(written["value"], current):
                    raise RuntimeError("parameter readback differs from actual written value")
                client.call("set_parameter", {"id": "arm.enabled", "value": 1}, expect_error=True)
                client.call(
                    "set_parameters",
                    {
                        "values": [
                            {"id": parameter, "value": 0},
                            {"id": "__missing__", "value": 1},
                        ]
                    },
                    expect_error=True,
                )
                if client.call("get_parameter", {"id": parameter})["value"] != current:
                    raise RuntimeError("failed batch changed a parameter")
            finally:
                # Keep the server-side source guard for restoration too. A source switch
                # must fail visibly rather than let cleanup write to a physical source.
                client.call("set_parameter", {"id": parameter, "value": original})
        if client.rpc("ping", token="incorrect-smoke-token")[0] != 401:
            raise RuntimeError("incorrect token was not rejected")
        if client.rpc("ping", extra_headers={"Origin": "https://untrusted.example"})[0] != 403:
            raise RuntimeError("untrusted Origin was not rejected")
        mode = "Mock write/read/restore, protected parameter, atomic batch" if write else "read-only parameter read"
        print(f"MCP {LEGACY if client.legacy else CURRENT}: discovery, tools, {mode}, auth and Origin passed.")
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8787/mcp")
    parser.add_argument("--token-env", default="BCR_MCP_TOKEN")
    parser.add_argument("--legacy", action="store_true", help="exercise the standardized 2025-11-25 handshake")
    parser.add_argument("--parameter", default="arm.j1")
    parser.add_argument("--value", type=float, default=90)
    parser.add_argument("--write", action="store_true", help="write and restore only on an authenticated Mock source")
    args = parser.parse_args()
    token = os.environ.get(args.token_env)
    if not token:
        parser.error(f"set {args.token_env}; tokens are never accepted on the command line or printed")
    if not math.isfinite(args.value):
        parser.error("--value must be finite")
    probe(Client(args.url, token, args.legacy), args.parameter, args.value, write=args.write)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError, KeyError, ValueError) as exc:
        print(f"MCP smoke failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
