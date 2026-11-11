import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import unittest
from unittest.mock import patch

from bcr_provider import Client, ProviderError


TOKEN = "f" * 64


class Handler(BaseHTTPRequestHandler):
    mode = "success"
    requests = 0

    def log_message(self, *args):
        pass

    def do_POST(self):
        type(self).requests += 1
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:9/stolen")
            self.end_headers()
            return
        payload = {"jsonrpc": "2.0", "id": request["id"], "result": {"structuredContent": {"data": {"ok": True}}}}
        if self.mode == "bad_id":
            payload["id"] = True
        elif self.mode == "no_result":
            payload.pop("result")
        elif self.mode == "reflected_error":
            payload["result"] = {
                "isError": True,
                "structuredContent": {"data": {"error": {"code": "fixture", "message": TOKEN}}},
            }
        raw = b"[]" if self.mode == "array" else json.dumps(payload).encode()
        if self.mode == "duplicate":
            raw = b'{"jsonrpc":"2.0","id":1,"id":1,"result":{}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("BCR-Provider-Id", "fixture-provider")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("BCR-Provider-Id", "fixture-provider")
        self.send_header("Content-Length", "0")
        self.end_headers()


class ClientTests(unittest.TestCase):
    def setUp(self):
        Handler.mode = "success"
        Handler.requests = 0
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/mcp"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_local_urls_only_and_no_header_injection(self):
        for url in (
            "http://localhost:8787/mcp",
            "https://127.0.0.1:8787/mcp",
            "http://127.0.0.1:8787/mcp?secret=x",
            "http://user:secret@127.0.0.1:8787/mcp",
        ):
            with self.assertRaises(ValueError):
                Client(url, TOKEN)
        with self.assertRaises(ValueError):
            Client(self.url, TOKEN, expected_provider_id="invalid\r\nheader")

    def test_environment_proxy_is_not_used_and_identity_is_confirmed(self):
        with patch.dict(
            os.environ,
            {"HTTP_PROXY": "http://127.0.0.1:9", "http_proxy": "http://127.0.0.1:9", "NO_PROXY": "", "no_proxy": ""},
        ):
            client = Client(self.url, TOKEN, expected_provider_id="fixture-provider")
            self.assertEqual(client.call("fixture"), {"ok": True})
        with self.assertRaises(ProviderError) as raised:
            Client(self.url, TOKEN, expected_provider_id="other").call("fixture")
        self.assertEqual(raised.exception.code, "provider_mismatch")

    def test_redirect_is_not_followed_or_retried(self):
        Handler.mode = "redirect"
        with self.assertRaises(ProviderError) as raised:
            Client(self.url, TOKEN).call("fixture")
        self.assertEqual(raised.exception.code, "redirect_refused")
        self.assertEqual(Handler.requests, 1)

    def test_malformed_and_mismatched_responses_fail_closed(self):
        for mode in ("bad_id", "no_result", "array", "duplicate"):
            Handler.mode = mode
            with self.subTest(mode=mode), self.assertRaises(ProviderError):
                Client(self.url, TOKEN).call("fixture")

    def test_reflected_credentials_are_not_exposed_by_errors(self):
        Handler.mode = "reflected_error"
        with self.assertRaises(ProviderError) as raised:
            Client(self.url, TOKEN).call("fixture")
        self.assertNotIn(TOKEN, str(raised.exception))
        self.assertEqual(raised.exception.code, "fixture")

    def test_stream_eof_fails_instead_of_busy_loop_or_replay(self):
        stream = Client(self.url, TOKEN, expected_provider_id="fixture-provider").events("console")
        with self.assertRaises(ProviderError) as raised:
            next(stream)
        self.assertEqual(raised.exception.code, "stream_closed")


if __name__ == "__main__":
    unittest.main()
