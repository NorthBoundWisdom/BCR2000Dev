import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "bcr_mcp_smoke", Path(__file__).resolve().parents[2] / "tools/mcp_smoke.py"
)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class FakeClient:
    def __init__(self, source, *, fail_after_write=False, switch_after_write=False):
        self.source = source
        self.legacy = False
        self.require_mock = False
        self.value = 12
        self.writes = []
        self.closed = False
        self.fail_after_write = fail_after_write
        self.switch_after_write = switch_after_write

    def rpc(self, method, **kwargs):
        if method == "server/discover":
            return 200, {"result": {"supportedVersions": [smoke.CURRENT]}}
        if method == "tools/list":
            return 200, {
                "result": {"tools": [{"name": n} for n in ("get_parameter", "set_parameter", "set_parameters")]}
            }
        return (401 if "token" in kwargs else 403), {}

    def call(self, name, args, expect_error=False):
        if name == "get_parameter":
            return {"value": self.value}
        if not self.require_mock or self.source != "mock":
            raise RuntimeError("source guard rejected request")
        self.writes.append((name, args))
        if expect_error:
            return None
        self.value = args["value"]
        if self.switch_after_write:
            self.source = "hardware"
        if self.fail_after_write:
            self.fail_after_write = False
            raise RuntimeError("lost response after accepted write")
        return {"value": self.value}

    def close(self):
        self.closed = True


class MCPSmokeTests(unittest.TestCase):
    def test_default_is_read_only_for_mock_hardware_and_unknown(self):
        for source in ("mock", "hardware", None):
            with self.subTest(source=source):
                client = FakeClient(source)
                smoke.probe(client, "arm.j1", 90)
                self.assertEqual(client.writes, [])
                self.assertEqual(client.value, 12)
                self.assertTrue(client.closed)

    def test_explicit_write_refuses_hardware_and_unknown_without_cleanup_write(self):
        for source in ("hardware", None):
            with self.subTest(source=source):
                client = FakeClient(source)
                with self.assertRaisesRegex(RuntimeError, "authenticated Mock"):
                    smoke.probe(client, "arm.j1", 90, write=True)
                self.assertEqual(client.writes, [])
                self.assertEqual(client.value, 12)
                self.assertTrue(client.closed)

    def test_mock_write_restores_after_success_and_lost_response(self):
        for fails in (False, True):
            with self.subTest(failure=fails):
                client = FakeClient("mock", fail_after_write=fails)
                if fails:
                    with self.assertRaisesRegex(RuntimeError, "lost response"):
                        smoke.probe(client, "arm.j1", 90, write=True)
                else:
                    smoke.probe(client, "arm.j1", 90, write=True)
                self.assertEqual(client.value, 12)
                self.assertEqual(client.writes[-1], ("set_parameter", {"id": "arm.j1", "value": 12}))
                self.assertTrue(client.require_mock)
                self.assertTrue(client.closed)

    def test_source_switch_denies_restoration_visibly_without_hardware_write(self):
        client = FakeClient("mock", switch_after_write=True)
        with self.assertRaisesRegex(RuntimeError, "source guard"):
            smoke.probe(client, "arm.j1", 90, write=True)
        self.assertEqual(len(client.writes), 1)
        self.assertTrue(client.require_mock)
        self.assertTrue(client.closed)
