#!/usr/bin/env python3
"""Unattended Windows BCR identity/snapshot verification; standard library only.

Only SysEx commands 01 (identity) and 43 (current-value snapshot) are allowed.
No preset selection, BCL/configuration transfer or firmware commands. Optional
CC writes require --test-cc and a matching, unambiguous baseline snapshot.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
import queue
import sys
import time

from midi_feedback_probe import CC, PTR, U32, UPTR, WinMM, bind, read_cc, resolve, _KEEPALIVE


class MIDIHDR(C.Structure):
    _fields_ = [("data", PTR), ("buffer_length", U32), ("recorded", U32),
                ("user", UPTR), ("flags", U32), ("next", PTR), ("reserved", UPTR),
                ("offset", U32), ("reserved_array", UPTR * 8)]


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
    backend = WinBCR()
    report = {"identity": None, "snapshotCCCount": 0, "writes": [], "visualLED": "not observed remotely"}
    original = None
    try:
        inputs, outputs = backend.ports(True), backend.ports(False)
        print(json.dumps({"inputs": [p.__dict__ for p in inputs], "outputs": [p.__dict__ for p in outputs]}), flush=True)
        source, destination = resolve(inputs, args.input, "input"), resolve(outputs, args.output, "output")
        if "bcr2000" not in source.name.lower() or "bcr2000" not in destination.name.lower():
            raise ValueError("Only explicitly named BCR2000 endpoints are supported")
        report.update(input=source.name, output=destination.name)
        backend.open(source, destination)
        _, replies = backend.query(1, args.wait)
        identities = [info for frame in replies if (info := identity_info(frame)) is not None]
        report["identity"] = identities[0] if identities else None
        baseline, _ = backend.query(0x43, args.wait)
        report["snapshotCCCount"] = len(baseline)
        print(json.dumps({"identity": report["identity"], "snapshotCCCount": len(baseline)}), flush=True)
        if args.test_cc is None:
            return report
        if args.test_cc in {0, 6, 32, 38, 96, 97, 98, 99, 100, 101} or not 1 <= args.test_cc < 120:
            raise ValueError("Choose a known ordinary absolute CC encoder")
        if report["identity"] is None:
            raise RuntimeError("No device identity response; no CC write attempted")
        value = snapshot_values(baseline, args.channel, args.test_cc)
        if value is None:
            raise RuntimeError("Target absent or snapshot unverified; no CC write attempted")
        original = CC(args.channel, args.test_cc, value)
        report["baselineValue"] = value
        for target in (0, 32, 64, 96, 127):
            backend.send(CC(args.channel, args.test_cc, target))
            pre_snapshot = backend.collect(0.25)
            messages, _ = backend.query(0x43, args.wait)
            observed = snapshot_values(messages, args.channel, args.test_cc)
            result = {"requested": target, "observed": observed, "matches": observed == target,
                      "echoCandidatesWithin250ms": sum(m.channel == args.channel and m.controller == args.test_cc for m in pre_snapshot)}
            report["writes"].append(result)
            print(json.dumps(result), flush=True)
        report["inputDropped"] = backend.events.dropped
        if backend.events.dropped:
            raise RuntimeError("Input overflow; roundtrip result is incomplete")
        report["valueRoundtripPassed"] = all(item["matches"] for item in report["writes"])
        return report
    finally:
        if original is not None:
            final = CC(original.channel, original.controller, 127) if args.hold_max else original
            try:
                backend.send(final)
                report["finalRequested"] = final.value
                time.sleep(0.1)
                snapshot, _ = backend.query(0x43, args.wait)
                report["finalObserved"] = snapshot_values(snapshot, final.channel, final.controller)
            except Exception as error:
                report["finalError"] = str(error)
        try:
            backend.close()
        finally:
            if args.report:
                Path(args.report).write_text(json.dumps(report, indent=2), encoding="utf-8")


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
