"""B-Control read-only request framing and shared snapshot validation."""

def request_bytes(command):
    if command not in (0x01, 0x43):
        raise ValueError("Only read-only identity/snapshot requests are allowed")
    return bytes([0xF0, 0, 0x20, 0x32, 0x7F, 0x15, command, 0xF7])


class SysExFrames:
    def __init__(self):
        self.partial = None
        self.frames = []

    def feed(self, data):
        for byte in data:
            if byte >= 0xF8:
                continue
            if byte == 0xF0:
                if self.partial is not None:
                    raise ValueError("Interrupted SysEx frame")
                self.partial = bytearray([byte])
            elif self.partial is not None:
                if byte >= 0x80 and byte != 0xF7:
                    raise ValueError("Invalid SysEx byte")
                self.partial.append(byte)
                if len(self.partial) > 8192:
                    raise ValueError("Unexpectedly large identity reply")
                if byte == 0xF7:
                    self.frames.append(bytes(self.partial))
                    self.partial = None


def identity_info(frame):
    if len(frame) < 9 or frame[:4] != bytes([0xF0, 0, 0x20, 0x32]) or frame[5:7] != bytes([0x15, 2]) or frame[-1] != 0xF7:
        return None
    return {"deviceID": frame[4], "model": "BCR2000", "identity": frame[7:-1].decode("ascii", errors="strict")}


def snapshot_values(messages, channel, controller):
    values = {m.value for m in messages if m.channel == channel and m.controller == controller}
    if len(values) > 1:
        raise ValueError("Conflicting values for the target identity in one snapshot")
    if not values:
        return None
    # A lone echo is insufficient evidence of a snapshot response.
    if len({(m.channel, m.controller) for m in messages}) < 2:
        return None
    return next(iter(values))
