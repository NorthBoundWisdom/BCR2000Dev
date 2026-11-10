#!/usr/bin/env python3
"""Unattended Windows BCR identity/snapshot verification; standard library only.

Only SysEx commands 01 (identity) and 43 (current-value snapshot) are allowed.
No preset selection, BCL/configuration transfer or firmware commands. Optional
CC writes require --test-cc and a matching, unambiguous baseline snapshot.
"""
import argparse
import ctypes as C
import json
import queue
import sys
import time

from midi_feedback_probe import PTR, U32, UPTR, WinMM, bind, read_cc, _KEEPALIVE


class MIDIHDR(C.Structure):
    _fields_ = [("data", PTR), ("buffer_length", U32), ("recorded", U32),
                ("user", UPTR), ("flags", U32), ("next", PTR), ("reserved", UPTR),
                ("offset", U32), ("reserved_array", UPTR * 8)]


from bcr_protocol import request_bytes, SysExFrames, identity_info, snapshot_values
from bcr_roundtrip import run_roundtrip


class WinBCR(WinMM):
    def __init__(self):
        super().__init__()
        self.buffers = {}
        self.long_events = queue.Queue()
        self.frames = SysExFrames()
        self.closing = False
        self.pending_output = []
        for direction in ("In", "Out"):
            for operation in ("PrepareHeader", "UnprepareHeader"):
                bind(self.api, "midi" + direction + operation, U32, [PTR, C.POINTER(MIDIHDR), U32])
        bind(self.api, "midiInAddBuffer", U32, [PTR, C.POINTER(MIDIHDR), U32])
        bind(self.api, "midiOutLongMsg", U32, [PTR, C.POINTER(MIDIHDR), U32])
        bind(self.api, "midiOutReset", U32, [PTR])

    def open(self, input_port, output_port=None):
        super().open(input_port, output_port)
        for _ in range(4):
            storage = C.create_string_buffer(4096)
            header = MIDIHDR(data=C.addressof(storage), buffer_length=len(storage))
            self.buffers[C.addressof(header)] = (header, storage)
            self.check(self.api.midiInPrepareHeader(self.input, C.byref(header), C.sizeof(header)), "Prepare input SysEx", True)
            self.check(self.api.midiInAddBuffer(self.input, C.byref(header), C.sizeof(header)), "Queue input SysEx", True)

    def handle_native_event(self, message, data):
        if message not in (0x3C4, 0x3C6):
            return super().handle_native_event(message, data)
        try:
            pair = self.buffers.get(data)
            if pair is None:
                raise RuntimeError("Driver returned an unknown SysEx buffer")
            header, storage = pair
            if header.recorded > len(storage):
                raise RuntimeError("Driver exceeded the prepared input buffer")
            payload = C.string_at(header.data, header.recorded)
            self.long_events.put((data, payload, message == 0x3C6))
        except Exception as error:
            self.events.put(RuntimeError("SysEx callback: " + str(error)))

    def pump(self):
        while True:
            try:
                address, payload, invalid = self.long_events.get_nowait()
            except queue.Empty:
                return
            if invalid:
                raise RuntimeError("WinMM reported malformed SysEx input")
            self.frames.feed(payload)
            if not self.closing:
                header, _ = self.buffers[address]
                header.recorded = 0
                self.check(self.api.midiInAddBuffer(self.input, C.byref(header), C.sizeof(header)), "Requeue SysEx input", True)

    def send_request(self, command):
        data = request_bytes(command)
        storage = C.create_string_buffer(data, len(data))
        header = MIDIHDR(data=C.addressof(storage), buffer_length=len(data))
        self.check(self.api.midiOutPrepareHeader(self.output, C.byref(header), C.sizeof(header)), "Prepare request")
        pair = (header, storage)
        self.pending_output.append(pair)
        try:
            self.check(self.api.midiOutLongMsg(self.output, C.byref(header), C.sizeof(header)), "Send request")
            deadline = time.monotonic() + 3
            while not header.flags & 1:
                self.pump()
                if time.monotonic() >= deadline:
                    self.check(self.api.midiOutReset(self.output), "Cancel timed-out request")
                    raise RuntimeError("SysEx send completion timed out")
                time.sleep(0.005)
        finally:
            result = self.api.midiOutUnprepareHeader(self.output, C.byref(header), C.sizeof(header))
            if result == 0:
                self.pending_output.remove(pair)
            else:
                _KEEPALIVE.append((self, header, storage))
                self.check(result, "Release request buffer")

    def collect(self, seconds):
        messages = []
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump()
            message = read_cc(self, timeout=0.01)
            if message:
                messages.append(message)
        self.pump()
        return messages

    def query(self, command, seconds):
        self.collect(0.05)  # Drain earlier short messages before the request.
        frame_start = len(self.frames.frames)
        self.send_request(command)
        messages = self.collect(seconds)
        return messages, self.frames.frames[frame_start:]

    def close(self):
        self.closing = True
        failures = []
        if self.input is not None:
            for name in ("midiInStop", "midiInReset"):
                try:
                    self.check(getattr(self.api, name)(self.input), name, True)
                except RuntimeError as error:
                    failures.append(str(error))
            for header, storage in self.buffers.values():
                if header.flags & 2:
                    result = self.api.midiInUnprepareHeader(self.input, C.byref(header), C.sizeof(header))
                    if result:
                        _KEEPALIVE.append((self, header, storage))
                        failures.append("Release input buffer failed: " + str(result))
        try:
            super().close()
        except RuntimeError as error:
            failures.append(str(error))
        if failures:
            _KEEPALIVE.append(self)
            raise RuntimeError("; ".join(failures))


def run(args):
    return run_roundtrip(args, WinBCR)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=int)
    parser.add_argument("--output", type=int)
    parser.add_argument("--test-cc", type=int)
    parser.add_argument("--channel", type=int, default=1)
    parser.add_argument("--wait", type=float, default=1)
    parser.add_argument("--hold-max", action="store_true")
    parser.add_argument("--report")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("This native probe runs on Windows")
    if not 1 <= args.channel <= 16 or not 0.2 <= args.wait <= 5:
        parser.error("channel must be 1..16 and wait 0.2..5 seconds")
    report = run(args)
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print("ERROR:", error, file=sys.stderr)
        raise SystemExit(1)
