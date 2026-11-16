"""Exercise the exact T24 helper/SDK/HTTP response-loss path with DNS forbidden."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
from socketserver import TCPServer
import subprocess
import sys
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Tests/H10Support/response_drop.py"


class ResponseDropLoopbackTests(unittest.TestCase):
    def test_literal_loopback_never_queries_dns_and_executes_upstream_tool_only_once(self):
        calls = []
        token = secrets.token_hex(32)

        class Upstream(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                call = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                calls.append((call, self.headers.get("Authorization")))
                body = json.dumps({"jsonrpc": "2.0", "id": call["id"], "result": {"isError": False}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        class LoopbackServer(ThreadingHTTPServer):
            def server_bind(self):
                TCPServer.server_bind(self)
                self.server_name, self.server_port = "localhost", self.server_address[1]

        server = LoopbackServer(("127.0.0.1", 0), Upstream)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        sdk = ROOT / "build/seed/SurfacePlugins/clients/python"
        self.assertTrue((sdk / "surface_control").is_dir(), "Materialize the locked SDK before workflow checks")
        wrapper = """import runpy,sys
from unittest.mock import patch
with patch('socket.getfqdn', side_effect=AssertionError('literal loopback must not query DNS')):
    runpy.run_path(sys.argv[1], run_name='__main__')
"""
        try:
            result = subprocess.run(
                [sys.executable, "-B", "-c", wrapper, str(HELPER)],
                input=json.dumps(
                    {"url": f"http://127.0.0.1:{server.server_port}/mcp", "token": token, "sdk": str(sdk)}
                ),
                capture_output=True,
                text=True,
                timeout=10,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
        self.assertNotIn(token, result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["actual_tool"], "start_agent")
        self.assertEqual(report["upstream_successes"], 1)
        self.assertEqual(report["proxy_requests"], 1)
        self.assertEqual(report["sdk_request_count"], 1)
        self.assertEqual(report["client_code"], "transport_unknown")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0]["method"], "tools/call")
        self.assertEqual(calls[0][0]["params"]["name"], "start_agent")
        self.assertEqual(calls[0][0]["params"]["arguments"], {"slot": 1})
        self.assertEqual(calls[0][1], "Bearer " + token)
