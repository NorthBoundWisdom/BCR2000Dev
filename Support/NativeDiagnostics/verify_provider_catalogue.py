#!/usr/bin/env python3
"""Read-only Provider 1.0 frozen-tool and registered-addition verifier."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import urllib.request


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def verify(tools, record, *, robot=False, chassis=False, surface=False, console=True):
    actual = {tool["name"]: tool for tool in tools}
    if len(actual) != len(tools):
        raise ValueError("duplicate tools")
    frozen = record["frozen_tools"]
    expected = set(
        record["baseline"]["default_tool_names"]
        if console
        else ["provider_capabilities", "provider_state", "provider_contract"]
    )
    if robot:
        expected.update(("robot_command", "robot_state", "robot_trace", "simulation_advance"))
    if chassis:
        expected.update(("chassis_command", "chassis_state", "chassis_trace", "simulation_advance"))
    additions = record["registered_additions"]
    if robot or chassis:
        expected.update(additions["shared"])
    if robot:
        expected.update(additions["robot"])
    if chassis:
        expected.update(additions["chassis"])
    if surface:
        expected.update(additions["surface"])
    changed = [
        name
        for name in actual.keys() & frozen.keys()
        if hashlib.sha256(canonical(actual[name])).hexdigest() != frozen[name]["sha256"]
    ]
    missing, unexpected = sorted(expected - actual.keys()), sorted(actual.keys() - expected)
    if changed or missing or unexpected:
        raise ValueError(json.dumps({"changed_frozen": changed, "missing": missing, "unexpected": unexpected}))
    return {
        "passed": True,
        "scope": "read-only tools/list descriptor compatibility; no device qualification",
        "actual_count": len(tools),
        "frozen_total": len(frozen),
        "present_frozen_count": len(actual.keys() & frozen.keys()),
        "absent_frozen": sorted(frozen.keys() - actual.keys()),
        "registered_additions": sorted(actual.keys() - frozen.keys()),
        "catalogue_sha256": hashlib.sha256(canonical(tools)).hexdigest(),
        "unchanged_frozen_descriptor_hashes": {
            name: frozen[name]["sha256"] for name in sorted(actual.keys() & frozen.keys())
        },
    }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if fp:
            fp.close()
        raise ValueError("redirect refused")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--record", type=Path, default=Path(__file__).resolve().parents[1] / "provider-tool-compatibility.json"
    )
    parser.add_argument("--catalogue", type=Path, help="offline tools/list tools array; does not access a device")
    parser.add_argument("--url")
    parser.add_argument("--token-stdin", action="store_true")
    parser.add_argument("--provider-id")
    parser.add_argument("--robot", action="store_true")
    parser.add_argument("--chassis", action="store_true")
    parser.add_argument("--surface", action="store_true")
    parser.add_argument("--no-console", action="store_true")
    args = parser.parse_args()
    try:
        if args.catalogue:
            if args.url or args.token_stdin:
                raise ValueError("offline and live arguments conflict")
            tools = json.loads(args.catalogue.read_text())
        else:
            from urllib.parse import urlsplit

            url = urlsplit(args.url or "")
            if not (
                args.token_stdin
                and url.scheme == "http"
                and url.hostname == "127.0.0.1"
                and url.port
                and url.path == "/mcp"
                and not url.query
                and not url.fragment
                and not url.username
                and not url.password
            ):
                raise ValueError("explicit IPv4 loopback URL and token stdin required")
            token = sys.stdin.read(65).strip()
            if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
                raise ValueError("invalid credential")
            headers = {
                "Authorization": "Bearer " + token,
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "MCP-Protocol-Version": "2026-07-28",
                "Mcp-Method": "tools/list",
            }
            if args.provider_id:
                headers["BCR-Provider-Id"] = args.provider_id
            request = urllib.request.Request(
                args.url,
                canonical(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "tools/list",
                        "params": {
                            "_meta": {
                                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                "io.modelcontextprotocol/clientCapabilities": {},
                            }
                        },
                    }
                ),
                headers,
            )
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            with opener.open(request, timeout=5) as response:
                if args.provider_id and response.headers.get("BCR-Provider-Id") != args.provider_id:
                    raise ValueError("provider identity mismatch")
                tools = json.load(response)["result"]["tools"]
        result = verify(
            tools,
            json.loads(args.record.read_text()),
            robot=args.robot,
            chassis=args.chassis,
            surface=args.surface,
            console=not args.no_console,
        )
        print(json.dumps(result, indent=2))
    except Exception as error:
        # Never echo transport exception text: a peer can reflect credentials.
        print(
            json.dumps(
                {"passed": False, "error": "catalogue_verification_failed", "detail": "invalid_catalogue_or_transport"}
            )
        )
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
