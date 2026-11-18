import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, call, patch

from tools import mcp_smoke, native_ui

with patch.dict(sys.modules, {"mcp_smoke": mcp_smoke, "native_ui": native_ui}):
    from tools import mcp_integration


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class MCPReadinessTests(unittest.TestCase):
    def wait(self, app, client, clock):
        with tempfile.TemporaryDirectory() as directory, patch.object(mcp_integration, "time", clock):
            mcp_integration.wait_for_listener(app, client, Path(directory))

    def test_delayed_response_and_other_startup_transport_failures_can_recover(self):
        clock = FakeClock()
        replies = iter(
            (TimeoutError("read"), ConnectionResetError("reset"), urllib.error.URLError("refused"), (200, {}))
        )

        def ping(method, *, timeout):
            reply = next(replies)
            if isinstance(reply, TimeoutError):
                clock.sleep(timeout)
            if isinstance(reply, Exception):
                raise reply
            return reply

        client = Mock(rpc=Mock(side_effect=ping))
        self.wait(Mock(poll=Mock(return_value=None)), client, clock)
        self.assertEqual(client.rpc.call_args_list, [call("ping", timeout=5)] * 4)
        self.assertAlmostEqual(clock.now, 5.3)

    def test_permanent_read_timeouts_stop_at_deadline_and_clip_last_probe(self):
        clock = FakeClock()

        def ping(method, *, timeout):
            clock.sleep(timeout)
            raise TimeoutError("read")

        client = Mock(rpc=Mock(side_effect=ping))
        with self.assertRaisesRegex(RuntimeError, "isolated listener did not start"):
            self.wait(Mock(poll=Mock(return_value=None)), client, clock)
        self.assertEqual(client.rpc.call_args_list[:2], [call("ping", timeout=5)] * 2)
        self.assertEqual(client.rpc.call_count, 3)
        self.assertAlmostEqual(client.rpc.call_args.kwargs["timeout"], 4.8)
        self.assertAlmostEqual(clock.now, 15)

    def test_http_success_arriving_after_deadline_is_rejected(self):
        clock = FakeClock()

        def ping(method, *, timeout):
            clock.sleep(15.01)
            return 200, {}

        client = Mock(rpc=Mock(side_effect=ping))
        with self.assertRaisesRegex(RuntimeError, "isolated listener did not start"):
            self.wait(Mock(poll=Mock(return_value=None)), client, clock)
        client.rpc.assert_called_once_with("ping", timeout=5)

    def test_unexpected_response_error_and_app_exit_are_not_retried(self):
        client = Mock(rpc=Mock(side_effect=ValueError("invalid JSON")))
        with self.assertRaisesRegex(ValueError, "invalid JSON"):
            self.wait(Mock(poll=Mock(return_value=None)), client, FakeClock())
        client.rpc.assert_called_once_with("ping", timeout=5)
        client.reset_mock()
        with self.assertRaisesRegex(RuntimeError, "isolated app exited"):
            self.wait(Mock(poll=Mock(return_value=1)), client, FakeClock())
        client.rpc.assert_not_called()

    def test_rpc_default_timeout_and_transport_failure_still_propagate(self):
        client = mcp_smoke.Client("http://127.0.0.1:12345/mcp", "local-fixture")
        with patch.object(mcp_smoke.urllib.request, "urlopen", side_effect=TimeoutError("read")) as request:
            with self.assertRaisesRegex(TimeoutError, "read"):
                client.rpc("tools/list")
        self.assertEqual(request.call_count, 1)
        self.assertEqual(request.call_args.kwargs, {"timeout": 5})
