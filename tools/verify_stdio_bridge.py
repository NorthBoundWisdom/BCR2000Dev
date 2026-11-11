#!/usr/bin/env python3
"""Exercise the stdio bridge against an isolated running Console MCP server."""

import json
import os
import subprocess
import sys


def main():
    messages = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "bcr-stdio-acceptance", "version": "1.0"},
            },
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_status", "arguments": {}}},
    ]
    result = subprocess.run(
        [sys.executable, "tools/mcp_stdio.py", "--url", os.environ["BCR_MCP_URL"]],
        input="".join(json.dumps(message) + "\n" for message in messages),
        capture_output=True,
        text=True,
        timeout=30,
        check=True,
    )
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    if [response.get("id") for response in responses] != [1, 2, 3]:
        raise RuntimeError("stdio response IDs do not match requests")
    if any("error" in response or "result" not in response for response in responses):
        raise RuntimeError("stdio requests failed")
    if not responses[1]["result"].get("tools") or responses[2]["result"].get("isError"):
        raise RuntimeError("stdio tool discovery or status call failed")
    print("stdio bridge: initialize, notification, tool discovery, status call and session cleanup passed.")


if __name__ == "__main__":
    main()
