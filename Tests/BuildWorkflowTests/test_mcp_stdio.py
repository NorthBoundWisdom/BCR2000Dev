import io
import json
import unittest

from tools.mcp_stdio import Bridge, serve


class MCPStdioTests(unittest.TestCase):
    def test_rejects_external_destinations_and_missing_credentials(self):
        for url in ("https://127.0.0.1/mcp", "http://example.com/mcp", "http://user@127.0.0.1/mcp"):
            with self.assertRaises(ValueError):
                Bridge(url, "fixture")
        with self.assertRaises(ValueError):
            Bridge("http://127.0.0.1:8787/mcp", "")

    def test_requests_reply_and_notifications_do_not(self):
        class Echo:
            def exchange(self, request):
                return {"jsonrpc": "2.0", "id": request.get("id"), "result": {"ok": True}}

        source = io.StringIO(
            '\n{"jsonrpc":"2.0","method":"ping","id":1}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
        )
        output = io.StringIO()
        serve(Echo(), source, output)
        self.assertEqual(json.loads(output.getvalue())["id"], 1)
        self.assertEqual(len(output.getvalue().splitlines()), 1)

    def test_failure_response_does_not_leak_exception_content(self):
        class Failed:
            def exchange(self, request):
                raise RuntimeError("fixture-secret")

        output = io.StringIO()
        serve(Failed(), io.StringIO('{"jsonrpc":"2.0","method":"ping","id":2}\n'), output)
        self.assertNotIn("fixture-secret", output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["id"], 2)

    def test_invalid_input_is_rejected(self):
        output = io.StringIO()
        serve(None, io.StringIO("broken\n[]\n"), output)
        self.assertEqual(len(output.getvalue().splitlines()), 2)
        self.assertTrue(all("error" in json.loads(line) for line in output.getvalue().splitlines()))
