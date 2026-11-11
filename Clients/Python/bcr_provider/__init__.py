"""Public, standard-library BCR provider client. No repository or app-internal imports."""

from __future__ import annotations

import http.client
import json
import urllib.error
import urllib.parse
import urllib.request

__version__ = "1.0.0"
PROTOCOL = "2026-07-28"
MAX_BYTES = 8 * 1024 * 1024


def _decode(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("Nonfinite JSON value")

    return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)


class ProviderError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if fp is not None:
            fp.close()
        raise ProviderError("redirect_refused", "Provider redirects are not followed")


class Client:
    """No automatic command retry, reconnect, source switch, approval or parameter replay."""

    def __init__(self, url, token, timeout=2, expected_provider_id=None):
        parsed = urllib.parse.urlsplit(url)
        if not (
            parsed.scheme == "http"
            and parsed.hostname == "127.0.0.1"
            and parsed.port is not None
            and 1024 <= parsed.port <= 65535
            and parsed.path == "/mcp"
            and not parsed.query
            and not parsed.fragment
            and parsed.username is None
            and parsed.password is None
        ):
            raise ValueError("Use an explicit IPv4-loopback MCP URL")
        if not isinstance(token, str) or not token or len(token) > 16384 or any(not 33 <= ord(c) < 127 for c in token):
            raise ValueError("A bearer credential is required; never pass it in argv or log it")
        self.url, self.token, self.timeout, self.parsed = url, token, timeout, parsed
        self.sequence = 0
        if expected_provider_id is not None and (
            not isinstance(expected_provider_id, str)
            or not expected_provider_id
            or len(expected_provider_id) > 128
            or any(not 33 <= ord(c) < 127 for c in expected_provider_id)
        ):
            raise ValueError("An explicit bounded provider identity is required")
        self.expected_provider_id = expected_provider_id
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())

    def _rpc(self, method, params):
        self.sequence += 1
        params = {
            **params,
            "_meta": {
                "io.modelcontextprotocol/protocolVersion": PROTOCOL,
                "io.modelcontextprotocol/clientCapabilities": {},
            },
        }
        body = json.dumps(
            {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}, allow_nan=False
        ).encode()
        if len(body) > 1024 * 1024:
            raise ProviderError("request_too_large", "Provider request exceeds 1 MiB")
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": PROTOCOL,
            "Mcp-Method": method,
        }
        if method == "tools/call":
            headers["Mcp-Name"] = params["name"]
        if self.expected_provider_id is not None:
            headers["BCR-Provider-Id"] = self.expected_provider_id
        try:
            request = urllib.request.Request(self.url, body, headers, method="POST")
            with self.opener.open(request, timeout=self.timeout) as response:
                if (
                    self.expected_provider_id is not None
                    and response.headers.get("BCR-Provider-Id") != self.expected_provider_id
                ):
                    raise ProviderError("provider_mismatch", "Provider identity was not confirmed")
                raw = response.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES or response.headers.get_content_type() != "application/json":
                    raise ProviderError("invalid_response", "Invalid provider response size or content type")
        except urllib.error.HTTPError as error:
            code = error.code
            error.close()
            raise ProviderError("http_" + str(code), "Provider HTTP request was rejected; no retry") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise ProviderError(
                "transport_failed", "Provider request failed; reconcile unknown write outcomes before a new command"
            ) from None
        try:
            reply = _decode(raw)
        except (ValueError, UnicodeError):
            raise ProviderError("invalid_response", "Provider returned invalid JSON") from None
        if (
            not isinstance(reply, dict)
            or reply.get("jsonrpc") != "2.0"
            or type(reply.get("id")) is not int
            or reply.get("id") != self.sequence
            or "error" in reply
        ):
            raise ProviderError("rpc_error", "Provider RPC response was rejected or mismatched")
        if not isinstance(reply.get("result"), dict):
            raise ProviderError("invalid_response", "Provider response has no structured result")
        return reply["result"]

    def discover(self):
        return self._rpc("server/discover", {})

    def tools(self):
        return self._rpc("tools/list", {})["tools"]

    def call(self, name, arguments=None):
        result = self._rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if not isinstance(result.get("structuredContent"), dict) or "data" not in result["structuredContent"]:
            raise ProviderError("invalid_response", "Provider response has no structured data")
        if "isError" in result and type(result["isError"]) is not bool:
            raise ProviderError("invalid_response", "Provider response has invalid error metadata")
        data = result["structuredContent"]["data"]
        if result.get("isError"):
            error = data.get("error") if isinstance(data, dict) else None
            code = error.get("code", "tool_error") if isinstance(error, dict) else "tool_error"
            message = (
                error.get("message", "Provider operation failed")
                if isinstance(error, dict)
                else str(error or "Provider operation failed")
            )
            raise ProviderError(code, message.replace(self.token, "[redacted]"))
        return data

    def events(self, channel="parameters", heartbeat_timeout=15):
        if channel not in ("parameters", "console", "devices"):
            raise ValueError("Unknown event channel")
        connection = http.client.HTTPConnection(self.parsed.hostname, self.parsed.port, timeout=heartbeat_timeout)
        methods = {
            "parameters": "notifications/bcr/parametersChanged",
            "console": "notifications/bcr/consoleEvents",
            "devices": "notifications/bcr/devicesChanged",
        }
        try:
            headers = {
                "Authorization": "Bearer " + self.token,
                "Accept": "text/event-stream",
                "MCP-Protocol-Version": PROTOCOL,
                "BCR-Event-Stream": channel,
            }
            if self.expected_provider_id is not None:
                headers["BCR-Provider-Id"] = self.expected_provider_id
            connection.request("GET", "/mcp", headers=headers)
            response = connection.getresponse()
            if response.status != 200:
                raise ProviderError("http_" + str(response.status), "Provider did not accept the event stream")
            if response.getheader("Content-Type") != "text/event-stream":
                raise ProviderError("stream_rejected", "Provider did not accept the event stream")
            if (
                self.expected_provider_id is not None
                and response.getheader("BCR-Provider-Id") != self.expected_provider_id
            ):
                raise ProviderError("provider_mismatch", "Provider stream identity was not confirmed")
            data, size = [], 0
            while True:
                line = response.fp.readline(MAX_BYTES + 1)
                if not line:
                    raise ProviderError(
                        "stream_closed",
                        "Provider stream ended; request a new snapshot before interpreting fresh inputs",
                    )
                size += len(line)
                if size > MAX_BYTES:
                    raise ProviderError("stream_too_large", "Provider event exceeds the bounded snapshot limit")
                if not line.strip():
                    if data:
                        notification = _decode(b"\n".join(data))
                        if notification.get("method") != methods[channel]:
                            raise ProviderError("invalid_event", "Unexpected provider notification")
                        yield notification["params"]
                    data, size = [], 0
                elif line.startswith(b"data: "):
                    data.append(line[6:].strip())
        except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError):
            raise ProviderError(
                "stream_failed", "Provider stream is no longer readable; obtain a fresh snapshot before new actions"
            ) from None
        finally:
            connection.close()


__all__ = ["Client", "ProviderError", "PROTOCOL", "__version__"]
