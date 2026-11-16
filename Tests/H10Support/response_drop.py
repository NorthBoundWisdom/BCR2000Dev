"""Execute one existing Mock Agent tool, then lose only its downstream response."""

import http.server
import importlib
import json
import socket
import socketserver
import sys
import threading
import urllib.request

sys.dont_write_bytecode = True
config = json.load(sys.stdin)
sys.path.insert(0, config["sdk"])
surface_control = importlib.import_module("surface_control")
Client, SurfaceError = surface_control.Client, surface_control.SurfaceError

state = {"proxy_requests": 0, "upstream_successes": 0, "actual_tool": None}


class Proxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        state["proxy_requests"] += 1
        body = self.rfile.read(int(self.headers["Content-Length"]))
        call = json.loads(body)
        state["actual_tool"] = call.get("params", {}).get("name")
        forwarded = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in {"host", "content-length", "connection"}
        }
        request = urllib.request.Request(config["url"], body, forwarded)
        with urllib.request.urlopen(request, timeout=3) as response:
            reply = json.load(response)
        state["upstream_successes"] += int(
            "result" in reply and "error" not in reply and not reply["result"].get("isError", False)
        )
        # The real host has replied successfully. Do not return that reply to the SDK.
        self.close_connection = True
        self.connection.shutdown(socket.SHUT_RDWR)
        self.connection.close()


class LoopbackHTTPServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # The literal loopback endpoint needs no reverse DNS; preserve the same TCP bind.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]


server = LoopbackHTTPServer(("127.0.0.1", 0), Proxy)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
client = Client(
    f"http://127.0.0.1:{server.server_port}/mcp",
    config["token"],
    "h10.mock",
    protocol="2026-07-28",
    timeout=3,
)
code = None
try:
    client.rpc("tools/call", {"name": "start_agent", "arguments": {"slot": 1}})
except SurfaceError as error:
    code = error.code
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)
report = {**state, "client_code": code, "sdk_request_count": client.sequence}
assert config["token"] not in json.dumps(report)
print(json.dumps(report, sort_keys=True))
