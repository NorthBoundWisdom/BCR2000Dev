import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("arm_sim", Path(__file__).parents[2] / "tools/arm_sim.py")
sim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sim)


class ArmSimulationTests(unittest.TestCase):
    peer = ("127.0.0.1", 12345)

    def frame(self, sequence, enabled, values=None):
        messages = [sim.message("/bcr/epoch", [self.epoch]), sim.message("/bcr/frame", [sequence]), sim.message("/bcr/enable", [int(enabled)])]
        messages += [sim.message("/bcr/param/" + key, [float(value)]) for key, value in (values or {}).items()]
        return sim.bundle(messages)

    def connect(self, arm, now=0):
        self.epoch = arm.epoch
        reply = arm.receive(sim.message("/bcr/heartbeat", [1]), self.peer, now)
        decoded = sim.decode_packet(reply[0][1])
        self.assertEqual(decoded[0][0], "/bcr/heartbeat")
        self.assertEqual(decoded[0][1], [1, arm.epoch])

    def test_codec_big_endian_and_bundle(self):
        packet = sim.message("/x", [1.0])
        self.assertEqual(packet, bytes([47, 120, 0, 0, 44, 102, 0, 0, 63, 128, 0, 0]))
        self.assertEqual(sim.decode_packet(sim.bundle([packet])), [("/x", [1.0])])
        with self.assertRaises(ValueError):
            sim.decode_packet(packet[:-1])

    def test_disabled_velocity_and_heartbeat_stop(self):
        arm = sim.ArmSimulation(speed=10)
        self.connect(arm)
        arm.receive(self.frame(1, False), self.peer, 0)
        arm.advance(0.1, 0.1)
        self.assertEqual(arm.actual["arm.j1"], 0)
        arm.receive(self.frame(2, True, {"arm.j1": 90}), self.peer, 0.1)
        arm.advance(0.05, 0.15)
        self.assertLessEqual(arm.actual["arm.j1"], 0.5)
        arm.advance(0.05, 0.4)
        previous = arm.actual["arm.j1"]
        self.assertFalse(arm.enabled)
        arm.advance(0.05, 0.5)
        self.assertEqual(arm.actual["arm.j1"], previous)

    def test_stop_frame_prevents_late_command_replay(self):
        arm = sim.ArmSimulation()
        self.connect(arm)
        arm.receive(self.frame(10, True, {"arm.j1": 90}), self.peer, 0.01)
        arm.receive(self.frame(11, False), self.peer, 0.02)
        arm.receive(self.frame(10, True, {"arm.j1": 90}), self.peer, 0.03)
        self.assertFalse(arm.enabled)
        self.assertEqual(arm.targets, arm.actual)
        self.assertEqual(arm.dropped, 1)

    def test_invalid_batch_is_atomic_and_other_peer_cannot_take_live_lease(self):
        arm = sim.ArmSimulation()
        self.connect(arm)
        target = dict(arm.targets)
        with self.assertRaises(ValueError):
            arm.receive(self.frame(1, True, {"arm.j1": 90, "unknown": 20}), self.peer, 0.1)
        self.assertEqual(arm.targets, target)
        self.assertFalse(arm.enabled)
        self.assertEqual(arm.receive(sim.message("/bcr/heartbeat", [1]), ("127.0.0.1", 9999), 0.1), [])

    def test_old_receiver_epoch_cannot_execute_after_restart(self):
        arm = sim.ArmSimulation()
        self.connect(arm)
        stale = self.frame(1, True, {"arm.j1": 90})
        arm.epoch = "b" * 32
        arm.receive(stale, self.peer, 0.1)
        self.assertFalse(arm.enabled)
        self.assertEqual(arm.actual, arm.targets)
        self.assertEqual(arm.dropped, 1)

    def test_sequence_wrap_and_telemetry_epoch(self):
        arm = sim.ArmSimulation()
        self.connect(arm)
        arm.receive(self.frame(0xffffffff, False), self.peer, 0.1)
        arm.receive(self.frame(0, True, {"arm.j1": 10}), self.peer, 0.2)
        self.assertTrue(arm.enabled)
        _, packet = arm.telemetry()
        values = sim.decode_packet(packet)
        self.assertEqual(values[0], ("/bcr/state/epoch", [arm.epoch]))
        self.assertEqual(values[1][0], "/bcr/state/frame")
        self.assertEqual(len(values), 10)


if __name__ == "__main__":
    unittest.main()
