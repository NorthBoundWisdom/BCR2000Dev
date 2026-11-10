#!/usr/bin/env python3
"""Read the BCR2000's current temporary preset and CC snapshot without changing it."""

import argparse
from pathlib import Path
import time

from bcr_protocol import identity_info
from diagnostic_io import write_json
from macos_bcr_roundtrip import MacBCR
from midi_feedback_probe import resolve


def capture(directory):
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    backend = MacBCR()
    try:
        source = resolve(backend.ports(True), None, "input")
        destination = resolve(backend.ports(False), None, "output")
        backend.open(source, destination)
        _, replies = backend.query(1, 1)
        identities = [info for frame in replies if (info := identity_info(frame)) is not None]
        if len(identities) != 1:
            raise ValueError("Expected exactly one BCR2000 identity response")
        backend.collect(0.1)
        start = len(backend.frames.frames)
        # Request Data, temporary preset only (0x7F). No preset selection or writes.
        backend._send_bytes(bytes([0xF0, 0, 0x20, 0x32, identities[0]["deviceID"], 0x15, 0x40, 0x7F, 0xF7]))
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            backend.collect(0.2)
            frames = backend.frames.frames[start:]
            if frames and frames[-1][9:-1].strip() == b"$end":
                break
        else:
            raise ValueError("Preset dump did not reach $end within 45 seconds")
        if not frames or backend.frames.partial is not None:
            raise ValueError("Missing or incomplete preset dump")
        data = b"".join(frames)
        if len(data) > 4 * 1024 * 1024:
            raise ValueError("Preset dump exceeds 4 MiB")
        messages, _ = backend.query(0x43, 1)
        snapshot = {}
        for message in messages:
            key = (message.channel, message.controller)
            if key in snapshot and snapshot[key] != message.value:
                raise ValueError("Conflicting snapshot values; keep controls still and retry")
            snapshot[key] = message.value
        if backend.events.dropped:
            raise ValueError("MIDI input overflow")
        path = directory / "current-preset.syx"
        path.write_bytes(data)
        path.chmod(0o600)
        write_json(
            directory / "snapshot.json",
            [
                {"channel": channel - 1, "number": number, "value": value}
                for (channel, number), value in sorted(snapshot.items())
            ],
        )
        print(f"Read-only capture: {len(frames)} frames, {len(snapshot)} CC values; profile not installed")
    finally:
        backend.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="New private local output directory (never commit captures)")
    capture(parser.parse_args().directory)
