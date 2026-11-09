#!/usr/bin/env python3
"""OSC/UDP arm simulator. Standard library only; defaults to loopback and stopped motion."""
import argparse
import math
import secrets
import select
import socket
import struct
import time
from urllib.parse import quote, unquote

DEFAULTS = {"arm.j1": 0.0, "arm.j2": 30.0, "arm.j3": -60.0, "arm.j4": -20.0,
            "arm.j5": 0.0, "arm.j6": 0.0, "arm.gripper": 40.0, "arm.speed": 50.0}


def osc_string(value):
    data = value.encode("ascii") + b"\0"
    return data + b"\0" * (-len(data) % 4)


def message(address, arguments):
    tags, payload = ",", b""
    for value in arguments:
        if isinstance(value, int):
            tags += "i"
            payload += struct.pack(">i", ((value + 2**31) % 2**32) - 2**31)
        elif isinstance(value, float):
            if not math.isfinite(value):
                raise ValueError("non-finite OSC float")
            tags += "f"
            payload += struct.pack(">f", value)
        elif isinstance(value, str):
            tags += "s"
            payload += osc_string(value)
        else:
            raise ValueError("unsupported OSC argument")
    return osc_string(address) + osc_string(tags) + payload


def bundle(messages):
    return osc_string("#bundle") + struct.pack(">Q", 1) + b"".join(struct.pack(">I", len(item)) + item for item in messages)


def decode_packet(data, depth=0):
    if depth > 8 or not data or len(data) % 4 or len(data) > 65507:
        raise ValueError("invalid OSC packet size")
    index = 0

    def read_string():
        nonlocal index
        end = data.find(b"\0", index)
        if end < 0:
            raise ValueError("unterminated OSC string")
        value = data[index:end].decode("ascii")
        padded = (end + 4) & ~3
        if padded > len(data) or any(data[end:padded]):
            raise ValueError("invalid OSC padding")
        index = padded
        return value

    address = read_string()
    if address == "#bundle":
        if len(data) - index < 8 or struct.unpack_from(">Q", data, index)[0] != 1:
            raise ValueError("only immediate OSC bundles are supported")
        index += 8
        result = []
        while index < len(data):
            if len(data) - index < 4:
                raise ValueError("truncated bundle")
            size = struct.unpack_from(">I", data, index)[0]
            index += 4
            if not size or size % 4 or size > len(data) - index:
                raise ValueError("bad bundle element length")
            result += decode_packet(data[index:index + size], depth + 1)
            index += size
        return result
    if not address.startswith("/"):
        raise ValueError("invalid OSC address")
    tags = read_string()
    if not tags.startswith(","):
        raise ValueError("missing OSC type tags")
    arguments = []
    for tag in tags[1:]:
        if tag == "s":
            arguments.append(read_string())
            continue
        if tag not in "if" or len(data) - index < 4:
            raise ValueError("bad OSC argument")
        value = struct.unpack_from(">i" if tag == "i" else ">f", data, index)[0]
        index += 4
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("non-finite OSC argument")
        arguments.append(value)
    if index != len(data):
        raise ValueError("trailing OSC bytes")
    return [(address, arguments)]


class ArmSimulation:
    def __init__(self, speed=45.0, timeout=0.35):
        if not math.isfinite(speed) or speed <= 0 or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("speed/timeout must be positive")
        self.speed, self.timeout = speed, timeout
        self.actual = dict(DEFAULTS)
        self.targets = dict(DEFAULTS)
        self.enabled = False
        self.peer = None
        self.last_heartbeat = None
        self.last_command = None
        self.last_command_at = None
        self.state_sequence = 0
        self.epoch = secrets.token_hex(16)
        self.dropped = 0

    @staticmethod
    def newer(sequence, previous):
        return previous is None or 0 < ((sequence - previous) & 0xffffffff) < 0x80000000

    def receive(self, data, peer, now):
        messages = decode_packet(data)
        if len(messages) == 1 and messages[0][0] == "/bcr/heartbeat":
            args = messages[0][1]
            if len(args) != 1 or type(args[0]) is not int:
                raise ValueError("invalid heartbeat")
            if self.peer is not None and self.peer != peer and self.last_heartbeat is not None and now - self.last_heartbeat < self.timeout:
                self.dropped += 1
                return []
            if self.peer != peer:
                self.enabled = False
                self.targets = dict(self.actual)
                self.last_command = None
            self.peer, self.last_heartbeat = peer, now
            return [(peer, message("/bcr/heartbeat", [args[0], self.epoch]))]
        if self.peer != peer or self.last_heartbeat is None or now - self.last_heartbeat >= self.timeout:
            self.dropped += 1
            return []
        if len(messages) < 3 or messages[0][0] != "/bcr/epoch" or messages[0][1] != [self.epoch]:
            self.dropped += 1
            return []
        if messages[1][0] != "/bcr/frame" or messages[2][0] != "/bcr/enable":
            raise ValueError("command requires sequence and enable header")
        sequence_args, enable_args = messages[1][1], messages[2][1]
        if len(sequence_args) != 1 or type(sequence_args[0]) is not int or len(enable_args) != 1 or type(enable_args[0]) is not int or enable_args[0] not in (0, 1):
            raise ValueError("invalid command headers")
        sequence = sequence_args[0] & 0xffffffff
        if not self.newer(sequence, self.last_command):
            self.dropped += 1
            return []
        updates = {}
        for address, args in messages[3:]:
            if not address.startswith("/bcr/param/") or len(args) != 1 or type(args[0]) is not float:
                raise ValueError("invalid parameter command")
            identifier = unquote(address[len("/bcr/param/"):], errors="strict")
            if identifier not in self.actual or identifier in updates:
                raise ValueError("unknown/duplicate parameter")
            updates[identifier] = args[0]
        enabled = enable_args[0] == 1
        if not enabled and updates:
            raise ValueError("stop frame must not contain motion values")
        self.last_command = sequence
        self.last_command_at = now
        self.enabled = enabled
        if enabled:
            self.targets.update(updates)
        else:
            self.targets = dict(self.actual)
        return []

    def advance(self, elapsed, now):
        if not math.isfinite(elapsed) or elapsed < 0:
            raise ValueError("invalid simulation clock")
        if self.last_heartbeat is None or now - self.last_heartbeat >= self.timeout:
            self.enabled = False
            self.targets = dict(self.actual)
            self.peer = None
            self.last_command = None
        # A live heartbeat cannot keep an old movement command alive.
        if self.last_command_at is None or now - self.last_command_at >= self.timeout:
            self.enabled = False
            self.targets = dict(self.actual)
        if self.enabled:
            allowance = self.speed * min(elapsed, 0.05)
            for identifier, target in self.targets.items():
                difference = target - self.actual[identifier]
                self.actual[identifier] += max(-allowance, min(allowance, difference))

    def telemetry(self):
        if self.peer is None:
            return None
        self.state_sequence = (self.state_sequence + 1) & 0xffffffff
        values = [message("/bcr/state/epoch", [self.epoch]), message("/bcr/state/frame", [self.state_sequence])]
        values += [message("/bcr/state/" + quote(identifier, safe="._-"), [float(value)]) for identifier, value in sorted(self.actual.items())]
        return self.peer, bundle(values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--speed", type=float, default=45)
    args = parser.parse_args()
    simulation = ArmSimulation(args.speed)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind((args.host, args.port))
        server.setblocking(False)
        print("Arm simulator listening on", server.getsockname(), "max velocity", args.speed, flush=True)
        previous = time.monotonic()
        next_telemetry = previous
        try:
            while True:
                readable, _, _ = select.select([server], [], [], 0.01)
                now = time.monotonic()
                if readable:
                    data, peer = server.recvfrom(65535)
                    try:
                        for destination, payload in simulation.receive(data, peer, now):
                            server.sendto(payload, destination)
                    except (ValueError, UnicodeError, struct.error) as exc:
                        print("Rejected OSC packet:", exc, flush=True)
                simulation.advance(now - previous, now)
                previous = now
                if now >= next_telemetry:
                    outgoing = simulation.telemetry()
                    if outgoing:
                        destination, payload = outgoing
                        server.sendto(payload, destination)
                    next_telemetry = now + 0.05
        except KeyboardInterrupt:
            simulation.enabled = False


if __name__ == "__main__":
    main()
