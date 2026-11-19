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


def send_state(sender, state_epoch, state_sequence, value):
    peer.sendto(
        bundle(
            [
                message("/bcr/state/epoch", "s", text(state_epoch)),
                message("/bcr/state/frame", "i", struct.pack("!I", state_sequence)),
                message("/bcr/state/arm.j1", "f", struct.pack("!f", value)),
            ]
        ),
        sender,
    )


peer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
peer.bind(("127.0.0.1", 0))
peer.settimeout(10)
print(peer.getsockname()[1], flush=True)
epoch = "0123456789abcdef0123456789abcdef"
replacement_epoch = "abcdef0123456789abcdef0123456789"
sequence = 0
pings = 0
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
        if "--restart-on-second-ping" in sys.argv:
            pings += 1
            active_epoch = epoch if pings == 1 else replacement_epoch
            peer.sendto(message("/bcr/heartbeat", "is", heartbeat + text(active_epoch)), sender)
            if pings == 1:
                send_state(sender, epoch, 100, 0)
            elif pings == 2:
                send_state(sender, epoch, 101, 0.75)
            elif pings == 3:
                send_state(sender, replacement_epoch, 1, -0.25)
                send_state(sender, replacement_epoch, 1, 0.75)
                send_state(sender, replacement_epoch, 0, 0.75)
            continue
        peer.sendto(message("/bcr/heartbeat", "is", heartbeat + text(epoch)), sender)
        for _ in range(128 if "--burst" in sys.argv else 1):
            sequence += 1
            send_state(sender, epoch, sequence, 0)
except (TimeoutError, ConnectionResetError, BrokenPipeError):
    pass
finally:
    peer.close()
