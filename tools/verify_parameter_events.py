#!/usr/bin/env python3
"""Validate authenticated parameter SSE streams against the isolated Mock app."""

import http.client
import json
import os
import urllib.parse

from mcp_smoke import Client, CURRENT, LEGACY


def read_event(response):
    while True:
        data = []
        while True:
            line = response.fp.readline().decode().strip()
            if not line:
                break
            if line.startswith("data: "):
                data.append(line[6:])
        if data:
            event = json.loads("\n".join(data))
            if event.get("method") != "notifications/bcr/parametersChanged":
                raise RuntimeError("unexpected SSE notification")
            return event["params"]


def main():
    endpoint = urllib.parse.urlsplit(os.environ["BCR_MCP_URL"])
    token = os.environ["BCR_MCP_TOKEN"]
    for legacy in (False, True):
        client = Client(os.environ["BCR_MCP_URL"], token, legacy)
        if legacy:
            status, _ = client.rpc(
                "initialize",
                {
                    "protocolVersion": LEGACY,
                    "capabilities": {},
                    "clientInfo": {"name": "event-acceptance", "version": "1"},
                },
            )
            if status != 200:
                raise RuntimeError("legacy initialize failed")
            client.rpc("notifications/initialized", notification=True)
        headers = {
            "Authorization": "Bearer " + token,
            "Accept": "text/event-stream",
            "MCP-Protocol-Version": LEGACY if legacy else CURRENT,
        }
        if legacy:
            headers["Mcp-Session-Id"] = client.session
        connection = http.client.HTTPConnection(endpoint.hostname, endpoint.port, timeout=5)
        connection.request("GET", "/mcp", headers=headers)
        response = connection.getresponse()
        if response.status != 200 or response.getheader("Content-Type") != "text/event-stream":
            raise RuntimeError("SSE negotiation failed")
        initial = read_event(response)
        if not initial["reset"] or "arm.j1" not in initial["values"]:
            raise RuntimeError("SSE initial snapshot missing")
        original = client.call("get_parameter", {"id": "arm.j1"})["value"]
        try:
            written = client.call("set_parameter", {"id": "arm.j1", "value": 37 if original != 37 else 38})["value"]
            changed = read_event(response)
            if changed["values"].get("arm.j1") != written or int(changed["revision"]) <= int(initial["revision"]):
                raise RuntimeError("SSE update differs from the authoritative parameter")
        finally:
            client.call("set_parameter", {"id": "arm.j1", "value": original})
            connection.close()
            client.close()
    denied = http.client.HTTPConnection(endpoint.hostname, endpoint.port, timeout=5)
    denied.request("GET", "/mcp", headers={"Accept": "text/event-stream", "MCP-Protocol-Version": CURRENT})
    if denied.getresponse().status != 401:
        raise RuntimeError("unauthenticated SSE was not rejected")
    denied.close()
    print("SSE: modern/legacy authentication, initial snapshot, revisioned updates and readback passed.")


if __name__ == "__main__":
    main()
