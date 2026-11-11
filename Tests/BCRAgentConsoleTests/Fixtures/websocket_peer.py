"""Minimal loopback RFC6455 peer for offline WebSocket and rosbridge wire acceptance."""

import base64
import hashlib
import json
import socket
import struct
import sys

rosbridge = sys.argv[1] == "rosbridge"
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(1)
listener.settimeout(10)
print(listener.getsockname()[1], flush=True)
connection, _ = listener.accept()
connection.settimeout(5)
stream = connection.makefile("rb")
headers = {}
assert stream.readline().startswith(b"GET /")
while True:
    line = stream.readline()
    if line == b"\r\n":
        break
    name, value = line.decode().split(":", 1)
    headers[name.lower()] = value.strip()
key = headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
accept = base64.b64encode(hashlib.sha1(key.encode()).digest()).decode()
connection.sendall(
    (
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Accept: "
        + accept
        + "\r\n\r\n"
    ).encode()
)


def exact(size):
    data = stream.read(size)
    if len(data) != size:
        raise EOFError()
    return data


def send(value, opcode=1):
    payload = json.dumps(value).encode() if opcode == 1 else value
    length = len(payload)
    header = bytes([0x80 | opcode, length]) if length < 126 else bytes([0x80 | opcode, 126]) + struct.pack("!H", length)
    connection.sendall(header + payload)


def event(value, topic):
    if rosbridge:
        value = {"op": "publish", "topic": topic, "msg": {"data": json.dumps(value)}}
    send(value)


sequence = 0
epoch = "fixture-peer"
try:
    while True:
        first, second = exact(2)
        opcode = first & 15
        length = second & 127
        if length == 126:
            length = struct.unpack("!H", exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", exact(8))[0]
        assert length <= 1_048_576
        mask = exact(4) if second & 128 else None
        payload = exact(length)
        if mask:
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        if opcode == 8:
            break
        if opcode == 9:
            send(payload, opcode=10)
            continue
        if opcode != 1:
            continue
        value = json.loads(payload)
        if rosbridge:
            if value["op"] in ("advertise", "subscribe"):
                assert value["type"] == "std_msgs/msg/String"
                continue
            assert value["op"] == "publish"
            value = json.loads(value["msg"]["data"])
        if value["type"] == "ping":
            if "--malformed" in sys.argv:
                send(b"{invalid-json", opcode=2)
                continue
            if "--restart" in sys.argv and sequence > 0:
                epoch = "fixture-peer-2"
            event(
                {"type": "pong", "epoch": epoch, "session": value["session"], "sequence": value["sequence"]},
                "/bcr/heartbeat",
            )
            sequence += 1
            event(
                {
                    "type": "state",
                    "epoch": epoch,
                    "session": value["session"],
                    "sequence": str(sequence),
                    "values": {"arm.j1": 0},
                },
                "/bcr/state",
            )
        elif value["type"] == "command":
            assert value["epoch"] == epoch
            assert value["enabled"] or not value["values"]
            print(json.dumps(value), flush=True)
except (EOFError, ConnectionResetError, BrokenPipeError):
    pass
finally:
    connection.close()
    listener.close()
