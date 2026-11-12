"""Small independent IPv4 UDP/OSC wire peer for receipt-clock and queue tests."""

import socket
import struct
import sys
import time


def text(value):
    data = value.encode("ascii") + b"\0"
    return data + b"\0" * ((-len(data)) % 4)


def message(address, tags, arguments):
    return text(address) + text("," + tags) + arguments


def bundle(messages):
    return text("#bundle") + struct.pack("!Q", 1) + b"".join(struct.pack("!I", len(item)) + item for item in messages)


peer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
peer.bind(("127.0.0.1", 0))
peer.settimeout(10)
print(peer.getsockname()[1], flush=True)
epoch = "0123456789abcdef0123456789abcdef"
sequence = 0
try:
    while True:
        data, sender = peer.recvfrom(65507)
        address_end = data.index(0)
        if data[:address_end] != b"/bcr/heartbeat":
            continue
        cursor = (address_end + 4) & ~3
        tags_end = data.index(0, cursor)
        assert data[cursor:tags_end] == b",i"
        cursor = (tags_end + 4) & ~3
        heartbeat = data[cursor : cursor + 4]
        if "--receipt-marker" in sys.argv:
            print("PING", flush=True)
        if "--delay-reply" in sys.argv:
            time.sleep(0.08)
        peer.sendto(message("/bcr/heartbeat", "is", heartbeat + text(epoch)), sender)
        for _ in range(128 if "--burst" in sys.argv else 1):
            sequence += 1
            peer.sendto(
                bundle(
                    [
                        message("/bcr/state/epoch", "s", text(epoch)),
                        message("/bcr/state/frame", "i", struct.pack("!I", sequence)),
                        message("/bcr/state/arm.j1", "f", struct.pack("!f", 0)),
                    ]
                ),
                sender,
            )
except (TimeoutError, ConnectionResetError, BrokenPipeError):
    pass
finally:
    peer.close()
