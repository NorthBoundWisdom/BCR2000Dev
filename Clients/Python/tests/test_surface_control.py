import copy
import unittest

from surface_control import Client, CommandCursor, SurfaceError


def discovery():
    return {
        "schema_version": 1,
        "contract_version": "1.0",
        "source": "simulation",
        "latest_sequence": "0",
        "expected": {
            "instance_id": "A",
            "epoch": "epoch",
            "mapping_revision": "map",
            "profile_id": "bcr2000.mock",
            "profile_version": "1.0",
        },
        "profile": {
            "id": "bcr2000.mock",
            "version": "1.0",
            "controls": [
                {
                    "id": name,
                    "input_kind": "absolute",
                    "encoding": "scalar",
                    "range": {"minimum": 0, "maximum": 127, "step": 1},
                    "mapping": {"kind": "parameter", "id": "simulation." + name},
                }
                for name in ("arm", "start", "pause", "cancel")
            ],
        },
    }


class Fixture(Client):
    def __init__(self):
        super().__init__("http://127.0.0.1:8787/mcp", "token", "A")
        self.head = 0
        self.rows = []
        self.values = {name: 0 for name in ("arm", "start", "pause", "cancel")}
        self.response_override = None
        self.response_time = 1

    def call(self, name, arguments=None):
        if self.response_override is not None:
            return self.response_override
        if name.endswith("discover"):
            value = discovery()
            value["latest_sequence"] = str(self.head)
            return value
        if name.endswith("snapshot"):
            return {
                "discovery": discovery(),
                "latest_sequence": str(self.head),
                "server_time": self.response_time,
                "inputs": dict(self.values),
                "feedback": {},
            }
        if name.endswith("events"):
            return {
                "expected": discovery()["expected"],
                "latest_sequence": str(self.head),
                "server_time": self.response_time,
                "events": copy.deepcopy(self.rows),
            }
        raise AssertionError(name)

    def event(self, control, value, **fields):
        self.head += 1
        row = {
            "expected": discovery()["expected"],
            "sequence": str(self.head),
            "source": "simulation",
            "kind": "input",
            "origin": "remote",
            "disposition": "accepted",
            "control_id": control,
            "encoding": "scalar",
            "value": value,
            "time": self.response_time,
            **fields,
        }
        self.rows.append(row)
        if row["kind"] == "input" and row["disposition"] == "accepted":
            self.values[control] = value


class SurfaceClientTests(unittest.TestCase):
    def cursor(self):
        client = Fixture()
        clock = [1]
        cursor = CommandCursor(
            client, {name: "simulation." + name for name in ("arm", "start", "pause", "cancel")}, clock=lambda: clock[0]
        )
        cursor.bootstrap()
        return client, cursor, clock

    def test_snapshot_is_state_not_an_action_and_feedback_is_not_input(self):
        client, cursor, _ = self.cursor()
        self.assertEqual(cursor.values, {"arm": 0, "start": 0, "pause": 0, "cancel": 0})
        client.event("arm", 127, kind="feedback")
        self.assertEqual(cursor.poll(), [])
        self.assertEqual(cursor.values["arm"], 0)

    def test_same_side_ticks_cannot_renew_intent(self):
        client, cursor, clock = self.cursor()
        client.event("arm", 100)
        sample = cursor.poll()[0]
        original = sample["expires_monotonic"]
        client.rows.clear()
        client.response_time = 1.5
        clock[0] = 1.5
        client.event("arm", 110)
        self.assertEqual(cursor.poll(), [])
        self.assertEqual(sample["expires_monotonic"], original)
        with self.assertRaises(SurfaceError):
            cursor.verify(sample)

    def test_old_state_and_gap_invalidate_without_recovery(self):
        client, cursor, _ = self.cursor()
        client.event("arm", 127)
        client.rows[0]["sequence"] = "2"
        with self.assertRaises(SurfaceError) as error:
            cursor.poll()
        self.assertEqual(error.exception.code, "event_gap")
        with self.assertRaises(SurfaceError):
            cursor.poll()

    def test_stale_event_cannot_gain_new_deadline_on_receipt(self):
        client, cursor, _ = self.cursor()
        client.event("arm", 127, time=0)
        client.response_time = 3
        with self.assertRaises(SurfaceError) as error:
            cursor.poll()
        self.assertEqual(error.exception.code, "input_stale")

    def test_context_source_and_instance_are_pinned(self):
        client = Fixture()
        bad = discovery()
        bad["source"] = "hardware"
        client.response_override = bad
        with self.assertRaises(SurfaceError):
            client.discover()
        bad = discovery()
        bad["expected"]["instance_id"] = "B"
        client.response_override = bad
        with self.assertRaises(SurfaceError):
            client.discover()
        bad = discovery()
        bad["expected"]["profile_version"] = "2.0"
        client.response_override = bad
        with self.assertRaises(SurfaceError):
            client.discover()

    def test_invalid_encodings_do_not_bootstrap(self):
        client = Fixture()
        bad = discovery()
        bad["profile"]["controls"][0]["encoding"] = "relative"
        client.response_override = bad
        cursor = CommandCursor(client, {name: "simulation." + name for name in ("arm", "start", "pause", "cancel")})
        with self.assertRaises(SurfaceError):
            cursor.bootstrap()

    def test_raw_failure_code_and_mutation_are_never_retried(self):
        client = Client("http://127.0.0.1:8787/mcp", "token", "A")
        calls = []

        def rpc(*args):
            calls.append(args)
            return {"isError": True, "structuredContent": {"code": "stale_sequence"}}

        client.rpc = rpc
        with self.assertRaises(SurfaceError) as error:
            client.call("surface_control_input", {})
        self.assertEqual(error.exception.code, "stale_sequence")
        self.assertEqual(len(calls), 1)

    def test_verify_clock_rollback_permanently_revokes_cursor(self):
        client, cursor, clock = self.cursor()
        client.event("arm", 127)
        sample = cursor.poll()[0]
        clock[0] = 0.5
        with self.assertRaises(SurfaceError):
            cursor.verify(sample)
        clock[0] = 1.5
        with self.assertRaises(SurfaceError) as error:
            cursor.verify(sample)
        self.assertEqual(error.exception.code, "recovery_required")

    def test_unknown_event_and_ignored_without_reason_cannot_preserve_arm(self):
        for fields in (
            {"kind": "future"},
            {"disposition": "future"},
            {"disposition": "ignored"},
            {"time": float("nan")},
            {"origin": "hardware"},
        ):
            client, cursor, _ = self.cursor()
            client.event("arm", 127, **fields)
            with self.assertRaises(SurfaceError):
                cursor.poll()
            self.assertTrue(cursor.invalidated)

    def test_poll_rejects_server_time_and_sequence_rollback(self):
        client, cursor, _ = self.cursor()
        client.response_time = 0.5
        with self.assertRaises(SurfaceError):
            cursor.poll()
        client, cursor, _ = self.cursor()
        client.latest_sequence = "2"
        with self.assertRaises(SurfaceError):
            cursor.poll()

    def test_snapshot_rejects_observed_highwater_rollback(self):
        client = Client("http://127.0.0.1:8787/mcp", "token", "A")
        client.expected = discovery()["expected"]
        client.latest_sequence = "2"
        client.server_time = 2
        value = {"discovery": discovery(), "latest_sequence": "1", "server_time": 3, "inputs": {}, "feedback": {}}
        client.call = lambda *_: value
        with self.assertRaises(SurfaceError):
            client.snapshot()
        value["latest_sequence"] = "2"
        value["server_time"] = 1
        with self.assertRaises(SurfaceError):
            client.snapshot()


if __name__ == "__main__":
    unittest.main()
