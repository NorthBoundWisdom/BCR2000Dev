#!/usr/bin/env python3
"""Native virtual BCR responder. Never targets a physical MIDI endpoint."""
import argparse
import contextlib
import ctypes as C
import io
import json
import queue
import sys
import threading
from types import SimpleNamespace

from bcr_protocol import SysExFrames
from bcr_roundtrip import run_roundtrip
from macos_bcr_roundtrip import MacBCR
from midi_feedback_probe import CC, MacMIDI, PTR, U32, bind, cc_bytes, mac_packet_bytes


def self_test(output_api):
    owner = MacMIDI()
    name = owner.string("Console Virtual BCR2000 Selftest")
    source, destination = U32(), U32()
    packets, failures = queue.Queue(), queue.Queue()
    stopped = threading.Event()
    state = {"value": 11}
    callback_type = C.CFUNCTYPE(None, PTR, PTR, PTR)
    def callback(packet_list, refcon, connection):
        try:
            for data in mac_packet_bytes(packet_list, owner._packet_offset, owner._aligned):
                packets.put_nowait(data)
        except Exception as error:
            failures.put(error)
    retained_callback = callback_type(callback)
    thread = None
    try:
        owner.check(owner.api.MIDIClientCreate(name, None, None, C.byref(owner.client)), "Create virtual client")
        create_source = bind(owner.api, "MIDISourceCreate", C.c_int32, [U32, PTR, C.POINTER(U32)])
        create_destination = bind(owner.api, "MIDIDestinationCreate", C.c_int32, [U32, PTR, PTR, PTR, C.POINTER(U32)])
        inject = bind(owner.api, "MIDIReceived", C.c_int32, [U32, PTR])
        owner.check(create_source(owner.client, name, C.byref(source)), "Create virtual source")
        owner.check(create_destination(owner.client, name, C.cast(retained_callback, PTR), None, C.byref(destination)), "Create virtual destination")
        input_index = next(i for i in range(owner.api.MIDIGetNumberOfSources()) if owner.api.MIDIGetSource(i) == source.value)
        output_index = next(i for i in range(owner.api.MIDIGetNumberOfDestinations()) if owner.api.MIDIGetDestination(i) == destination.value)
        def send_input(raw):
            data = (C.c_ubyte * len(raw)).from_buffer_copy(raw)
            packet = owner.api.MIDIPacketListInit(owner._storage)
            if not owner.api.MIDIPacketListAdd(owner._storage, len(owner._storage), packet, 0, len(raw), data):
                raise RuntimeError("Virtual response packet construction failed")
            owner.check(inject(source, owner._storage), "Inject virtual reply")
        def responder():
            frames = SysExFrames()
            try:
                while not stopped.is_set():
                    try:
                        data = packets.get(timeout=0.05)
                    except queue.Empty:
                        continue
                    for packed in cc_bytes(data):
                        message = CC.unpack(packed)
                        if message.channel == 1 and message.controller == 74:
                            state["value"] = message.value
                    before = len(frames.frames)
                    frames.feed(data)
                    for frame in frames.frames[before:]:
                        if frame == bytes.fromhex("F0 00 20 32 7F 15 01 F7"):
                            # Fragment the response across packets to test callback state.
                            reply = bytes.fromhex("F0 00 20 32 00 15 02") + b"BCR2000 1.10\xF7"
                            send_input(reply[:10]); send_input(reply[10:])
                        elif frame == bytes.fromhex("F0 00 20 32 7F 15 43 F7"):
                            send_input(bytes([0xB0, 74, state["value"], 0xB0, 75, 20]))
                        else:
                            raise RuntimeError("Unexpected SysEx in read-only self-test")
            except Exception as error:
                failures.put(error)
        thread = threading.Thread(target=responder, daemon=True)
        thread.start()
        args = SimpleNamespace(input=input_index, output=output_index, test_cc=74, channel=1,
                               wait=0.2, hold_max=False, expected_identity="BCR2000 1.10", report=None)
        with contextlib.redirect_stdout(io.StringIO()):
            report = run_roundtrip(args, lambda: MacBCR(output_api))
        if not failures.empty():
            raise failures.get()
        if not report.get("valueRoundtripPassed") or report.get("finalObserved") != 11 or state["value"] != 11:
            raise RuntimeError("Virtual device roundtrip or restoration failed")
        return {"status": "passed", "api": output_api, "physicalDestinationUsed": False,
                "identityVerified": report["identity"]["identity"], "fiveValuesReadBack": True, "restorationVerified": True}
    finally:
        stopped.set()
        if thread is not None:
            thread.join(timeout=2)
            if thread.is_alive():
                raise RuntimeError("Virtual responder did not stop")
        owner.close()
        owner.cf.CFRelease(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mac-api", choices=["legacy", "ump1", "ump2"], default="legacy")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native self-test requires macOS")
    print(json.dumps(self_test(args.mac_api)))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print("ERROR:", error, file=sys.stderr)
        raise SystemExit(1)
