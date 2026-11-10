#!/usr/bin/env python3
"""Guarded, unattended macOS BCR queries; only identity and snapshot SysEx.

Default is read-only queries. --test-cc must name a previously learned ordinary
absolute encoder, and requires a matching device identity and baseline snapshot.
"""

import argparse
import json
import queue
import sys
import time

from bcr_protocol import request_bytes, SysExFrames
from bcr_roundtrip import run_roundtrip
from midi_feedback_probe import MacMIDI, read_cc


def request_words(command):
    payload = request_bytes(command)[1:-1]
    return [
        0x30000000 | len(payload) << 16 | payload[0] << 8 | payload[1],
        payload[2] << 24 | payload[3] << 16 | payload[4] << 8 | payload[5],
    ]


class MacBCR(MacMIDI):
    def __init__(self, output_api="legacy"):
        super().__init__(output_api=output_api)
        self.raw_events = queue.Queue(maxsize=8192)
        self.frames = SysExFrames()

        def queued(data):
            try:
                self.raw_events.put_nowait(data)
            except queue.Full:
                self.events.dropped += 1

        self.raw_input = queued

    def pump(self):
        for _ in range(8192):
            try:
                self.frames.feed(self.raw_events.get_nowait())
            except queue.Empty:
                return
        raise RuntimeError("Raw input flood exceeded one bounded pump cycle")

    def send_request(self, command):
        if self.output_api == "legacy":
            self._send_bytes(request_bytes(command))
        else:
            self._send_words(request_words(command), 1 if self.output_api == "ump1" else 2)

    def collect(self, seconds):
        messages, deadline = [], time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump()
            message = read_cc(self, timeout=0.01)
            if message:
                messages.append(message)
        self.pump()
        if self.events.dropped:
            raise RuntimeError("Native input overflow; result is incomplete")
        return messages

    def query(self, command, seconds):
        self.collect(0.05)
        start = len(self.frames.frames)
        self.send_request(command)
        return self.collect(seconds), self.frames.frames[start:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=int)
    parser.add_argument("--output", type=int)
    parser.add_argument("--test-cc", type=int)
    parser.add_argument("--channel", type=int, default=1)
    parser.add_argument("--wait", type=float, default=1)
    parser.add_argument("--hold-max", action="store_true")
    parser.add_argument("--expected-identity")
    parser.add_argument("--mac-api", choices=["legacy", "ump1", "ump2"], default="legacy")
    parser.add_argument("--report")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native macOS probe required")
    if not 1 <= args.channel <= 16 or not 0.2 <= args.wait <= 5:
        parser.error("Invalid channel or response wait")
    report = run_roundtrip(args, lambda: MacBCR(args.mac_api))
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print("ERROR:", error, file=sys.stderr)
        raise SystemExit(1)
