import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import subprocess
from socketserver import TCPServer
from unittest.mock import patch
import sys
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "Support/NativeDiagnostics/verify_provider_catalogue.py"
spec = importlib.util.spec_from_file_location("catalogue", CHECKER)
catalogue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalogue)


class CatalogueCompatibilityTests(unittest.TestCase):
    def test_frozen_descriptor_mutation_and_unregistered_addition_fail(self):
        tool = {"name": "frozen", "description": "unchanged", "inputSchema": {}, "outputSchema": {}}
        record = {
            "frozen_tools": {"frozen": {"sha256": __import__("hashlib").sha256(catalogue.canonical(tool)).hexdigest()}},
            "baseline": {"default_tool_names": ["frozen"]},
            "registered_additions": {},
        }
        self.assertEqual(catalogue.verify([tool], record)["present_frozen_count"], 1)
        with self.assertRaises(ValueError):
            catalogue.verify([{**tool, "description": "changed"}], record)
        with self.assertRaises(ValueError):
            catalogue.verify([tool, {"name": "unregistered"}], record)

    def test_reflected_credential_in_unregistered_peer_tool_is_never_printed(self):
        token = secrets.token_hex(32)

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                raw = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"tools": [{"name": token}]}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        class LoopbackServer(ThreadingHTTPServer):
            def server_bind(self):
                # HTTPServer.server_bind calls getfqdn(), which can stall for tens of
                # seconds on CI DNS. This literal-loopback fixture never needs DNS.
                TCPServer.server_bind(self)
                self.server_name, self.server_port = "localhost", self.server_address[1]

        with patch("socket.getfqdn", side_effect=AssertionError("Loopback fixture must not query DNS")):
            server = LoopbackServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER),
                    "--record",
                    str(ROOT / "docs/provider-tool-compatibility.json"),
                    "--url",
                    f"http://127.0.0.1:{server.server_port}/mcp",
                    "--token-stdin",
                ],
                input=token,
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(token, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)["error"], "catalogue_verification_failed")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
