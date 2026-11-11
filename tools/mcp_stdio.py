#!/usr/bin/env python3
"""Bridge newline-delimited MCP stdio requests to the local Console HTTP endpoint.

Set BCR_MCP_TOKEN in the environment. stdout contains only JSON-RPC responses.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


class Bridge:
    def __init__(self, url, token):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.username or parsed.password:
            raise ValueError("MCP bridge requires an http://127.0.0.1 endpoint")
        if not token or "\n" in token or "\r" in token:
            raise ValueError("BCR_MCP_TOKEN is missing or invalid")
        self.url = url
        self.token = token
        self.session = None
        self.protocol = "2025-11-25"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def exchange(self, message):
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self.protocol,
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        request = urllib.request.Request(self.url, data=json.dumps(message).encode(), headers=headers, method="POST")
        try:
            response = self.opener.open(request, timeout=15)
        except urllib.error.HTTPError as error:
            # Do not copy the response body into diagnostics; it may contain user content.
            raise RuntimeError(f"MCP HTTP status {error.code}") from None
        with response:
            if response.headers.get("Mcp-Session-Id"):
                self.session = response.headers["Mcp-Session-Id"]
            body = response.read(1_048_577)
            if len(body) > 1_048_576:
                raise RuntimeError("MCP response exceeds 1 MiB")
            if not body:
                return None
            result = json.loads(body)
            if message.get("method") == "initialize":
                self.protocol = result.get("result", {}).get("protocolVersion", self.protocol)
            return result

    def close(self):
        if not self.session:
            return
        request = urllib.request.Request(
            self.url,
            headers={
                "Authorization": "Bearer " + self.token,
                "Mcp-Session-Id": self.session,
                "MCP-Protocol-Version": self.protocol,
            },
            method="DELETE",
        )
        with self.opener.open(request, timeout=5):
            pass
        self.session = None


def serve(bridge, source, destination):
    while True:
        line = source.readline(1_048_578)
        if not line:
            return
        if len(line.encode()) > 1_048_576:
            raise ValueError("MCP input exceeds 1 MiB")
        if not line.strip():
            continue
        request = None
        try:
            request = json.loads(line)
            if (
                not isinstance(request, dict)
                or request.get("jsonrpc") != "2.0"
                or not isinstance(request.get("method"), str)
            ):
                raise ValueError("Invalid JSON-RPC request")
            result = bridge.exchange(request)
        except (ValueError, RuntimeError, urllib.error.URLError, TimeoutError):
            result = {
                "jsonrpc": "2.0",
                "id": request.get("id") if isinstance(request, dict) else None,
                "error": {"code": -32603, "message": "Local MCP request failed"},
            }
        if result is not None and (not isinstance(request, dict) or "id" in request):
            destination.write(json.dumps(result, ensure_ascii=False) + "\n")
            destination.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8787/mcp")
    args = parser.parse_args()
    bridge = Bridge(args.url, os.environ.get("BCR_MCP_TOKEN", ""))
    try:
        serve(bridge, sys.stdin, sys.stdout)
    finally:
        bridge.close()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, urllib.error.URLError, TimeoutError):
        print("Local MCP bridge stopped: check endpoint, credentials and server status.", file=sys.stderr)
        sys.exit(1)
