#!/usr/bin/env python3
"""Dependency-free CC feedback diagnostic: WinMM on Windows, CoreMIDI on macOS.

No SysEx, preset writes, drivers or third-party Python packages. Device input learns
one absolute seven-bit CC encoder; output is opt-in with --mode test.
"""
import argparse
import ctypes as C
from dataclasses import dataclass
import platform
import queue
import sys
import time

_KEEPALIVE = []  # Retain callbacks if a native driver refuses to close.

U16, U32, UPTR, PTR = C.c_uint16, C.c_uint32, C.c_size_t, C.c_void_p


@dataclass(frozen=True)
class Port:
    id: int
    name: str


@dataclass(frozen=True)
class CC:
    channel: int
    controller: int
    value: int

    def packed(self):
        if not (1 <= self.channel <= 16 and 0 <= self.controller < 128 and 0 <= self.value < 128):
            raise ValueError("CC channel/data out of range")
        return (0xB0 | (self.channel - 1)) | self.controller << 8 | self.value << 16

    @classmethod
    def unpack(cls, packed):
        status = packed & 255
        if status & 0xF0 != 0xB0:
            return None
        number, value = packed >> 8 & 255, packed >> 16 & 255
        if number >= 128 or value >= 128:
            raise ValueError("Invalid MIDI data byte")
        return cls((status & 15) + 1, number, value)


def ump_cc(message, protocol):
    message.packed()  # Shared validation.
    channel = message.channel - 1
    if protocol == 1:
        return [0x20B00000 | channel << 16 | message.controller << 8 | message.value]
    if protocol == 2:
        return [0x40B00000 | channel << 16 | message.controller << 8,
                message.value * 0xFFFFFFFF // 127]
    raise ValueError("UMP protocol must be 1 or 2")


class InputEvents:
    def __init__(self):
        self.queue = queue.Queue(maxsize=8192)
        self.dropped = 0

    def put(self, packed):
        try:
            self.queue.put_nowait(packed)
        except queue.Full:
            self.dropped += 1

    def read(self, timeout=0.05):
        try:
            return self.queue.get(timeout=timeout)
        except queue.Empty:
            return None


def bind(lib, name, result, arguments):
    function = getattr(lib, name)
    function.restype, function.argtypes = result, arguments
    return function


def resolve(ports, selected, direction):
    if selected is not None:
        matches = [p for p in ports if p.id == selected]
    else:
        bcr = [p for p in ports if "bcr2000" in p.name.casefold()]
        preferred = [p for p in bcr if "port 1" in p.name.casefold()]
        matches = preferred if len(preferred) == 1 else bcr
    if len(matches) != 1:
        raise ValueError(f"Select exactly one --{direction} ID from the printed list.")
    return matches[0]


def validate_output(port, allow_other=False, explicit_input=None, explicit_output=None):
    if "bcr2000" in port.name.casefold():
        return
    if not allow_other or explicit_input is None or explicit_output is None:
        raise ValueError("Non-BCR interface requires --allow-other-device and explicit --input/--output IDs.")


class InputCaps(C.Structure):
    _fields_ = [("manufacturer", U16), ("product", U16), ("version", U32),
                ("name", U16 * 32), ("support", U32)]


class OutputCaps(C.Structure):
    _fields_ = [("manufacturer", U16), ("product", U16), ("version", U32),
                ("name", U16 * 32), ("technology", U16), ("voices", U16),
                ("notes", U16), ("channel_mask", U16), ("support", U32)]


class WinMM:
    def __init__(self):
        self.api = C.WinDLL("winmm.dll")
        self.events = InputEvents()
        self.input = self.output = None
        self.callback = None
        for direction, caps in [("In", InputCaps), ("Out", OutputCaps)]:
            bind(self.api, "midi" + direction + "GetNumDevs", U32, [])
            bind(self.api, "midi" + direction + "GetDevCapsW", U32, [UPTR, C.POINTER(caps), U32])
            bind(self.api, "midi" + direction + "Open", U32, [C.POINTER(PTR), U32, UPTR, UPTR, U32])
            bind(self.api, "midi" + direction + "Close", U32, [PTR])
            bind(self.api, "midi" + direction + "GetErrorTextW", U32, [U32, C.c_wchar_p, U32])
        for name in ["midiInStart", "midiInStop", "midiInReset"]:
            bind(self.api, name, U32, [PTR])
        bind(self.api, "midiOutShortMsg", U32, [PTR, U32])

    def check(self, status, operation, input=False):
        if status:
            text = C.create_unicode_buffer(256)
            getattr(self.api, "midiInGetErrorTextW" if input else "midiOutGetErrorTextW")(status, text, 256)
            raise RuntimeError(f"{operation}: {status} {text.value}")

    def ports(self, input):
        prefix, caps_type = ("midiIn", InputCaps) if input else ("midiOut", OutputCaps)
        result = []
        for index in range(getattr(self.api, prefix + "GetNumDevs")()):
            caps = caps_type()
            self.check(getattr(self.api, prefix + "GetDevCapsW")(index, C.byref(caps), C.sizeof(caps)), "Get port", input)
            result.append(Port(index, bytes(caps.name).decode("utf-16-le").split("\0")[0]))
        return result

    def open(self, input_port, output_port=None):
        callback_type = C.WINFUNCTYPE(None, PTR, U32, UPTR, UPTR, UPTR)
        def received(handle, message, instance, data, timestamp):
            # No WinMM calls, printing or waits in the driver callback.
            if message in (0x3C3, 0x3CC):
                self.events.put(int(data))
            elif message == 0x3C5:
                self.events.put(RuntimeError("WinMM reported malformed input"))
        self.callback = callback_type(received)  # Retained until midiInClose succeeds.
        handle = PTR()
        self.check(self.api.midiInOpen(C.byref(handle), input_port.id, C.cast(self.callback, PTR).value, 0, 0x30000), "Open input", True)
        self.input = handle
        self.check(self.api.midiInStart(handle), "Start input", True)
        if output_port:
            handle = PTR()
            self.check(self.api.midiOutOpen(C.byref(handle), output_port.id, 0, 0, 0), "Open output")
            self.output = handle

    def send(self, message):
        self.check(self.api.midiOutShortMsg(self.output, message.packed()), "Send CC")

    def close(self):
        errors = []
        if self.input is not None:
            for operation in ["midiInStop", "midiInReset", "midiInClose"]:
                try:
                    self.check(getattr(self.api, operation)(self.input), operation, True)
                except RuntimeError as error:
                    errors.append(str(error))
            # Keep self.callback alive even if the driver could not close the handle.
            self.input = None
        if self.output is not None:
            try:
                self.check(self.api.midiOutClose(self.output), "Close output")
            except RuntimeError as error:
                errors.append(str(error))
            self.output = None
        if errors:
            _KEEPALIVE.append(self)
            raise RuntimeError("; ".join(errors))


def mac_cc_packets(packet_list, offset, aligned):
    result = []
    count = U32.from_address(packet_list).value
    packet = packet_list + offset
    for _ in range(count):
        length = U16.from_address(packet + 8).value
        data = C.string_at(packet + 10, length)
        index = 0
        while index < len(data):
            status = data[index]
            if status & 0xF0 == 0xB0 and index + 2 < len(data):
                result.append(status | data[index+1] << 8 | data[index+2] << 16)
                index += 3
            elif 0x80 <= status < 0xF0:
                index += 2 if status & 0xF0 in (0xC0, 0xD0) else 3
            elif status == 0xF0:
                end = data.find(b"\xF7", index + 1)
                index = len(data) if end < 0 else end + 1
            else:
                index += 1
        packet += 10 + length
        if aligned:
            packet = (packet + 3) & ~3
    return result


class MacMIDI:
    """Plain C callback boundary, independent of the Swift app/actors/UI."""
    def __init__(self, packet_repeats=1, output_api="legacy"):
        if not 1 <= packet_repeats <= 16:
            raise ValueError("packet_repeats must be 1..16")
        if output_api not in ("legacy", "ump1", "ump2"):
            raise ValueError("Unknown CoreMIDI output API")
        self.packet_repeats = packet_repeats
        self.output_api = output_api
        self.api = C.CDLL("/System/Library/Frameworks/CoreMIDI.framework/CoreMIDI")
        self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.events = InputEvents()
        self.client = U32()
        self.input = U32()
        self.output = U32()
        self.source = None
        self.destination = None
        self.callback = None
        for name in ["MIDIGetNumberOfSources", "MIDIGetNumberOfDestinations"]:
            bind(self.api, name, UPTR, [])
        for name in ["MIDIGetSource", "MIDIGetDestination"]:
            bind(self.api, name, U32, [UPTR])
        bind(self.api, "MIDIObjectGetStringProperty", C.c_int32, [U32, PTR, C.POINTER(PTR)])
        bind(self.api, "MIDIObjectGetIntegerProperty", C.c_int32, [U32, PTR, C.POINTER(C.c_int32)])
        bind(self.cf, "CFStringCreateWithCString", PTR, [PTR, C.c_char_p, U32])
        bind(self.cf, "CFStringGetCString", C.c_bool, [PTR, PTR, C.c_long, U32])
        bind(self.cf, "CFRelease", None, [PTR])
        bind(self.api, "MIDIClientCreate", C.c_int32, [PTR, PTR, PTR, C.POINTER(U32)])
        bind(self.api, "MIDIInputPortCreate", C.c_int32, [U32, PTR, PTR, PTR, C.POINTER(U32)])
        bind(self.api, "MIDIOutputPortCreate", C.c_int32, [U32, PTR, C.POINTER(U32)])
        bind(self.api, "MIDIPortConnectSource", C.c_int32, [U32, U32, PTR])
        bind(self.api, "MIDIPortDisconnectSource", C.c_int32, [U32, U32])
        for name in ["MIDIPortDispose", "MIDIClientDispose"]:
            bind(self.api, name, C.c_int32, [U32])
        bind(self.api, "MIDIPacketListInit", PTR, [PTR])
        bind(self.api, "MIDIPacketListAdd", PTR, [PTR, UPTR, PTR, C.c_uint64, UPTR, PTR])
        bind(self.api, "MIDISend", C.c_int32, [U32, U32, PTR])
        bind(self.api, "MIDIEventListInit", PTR, [PTR, C.c_int32])
        bind(self.api, "MIDIEventListAdd", PTR, [PTR, UPTR, PTR, C.c_uint64, UPTR, C.POINTER(U32)])
        bind(self.api, "MIDISendEventList", C.c_int32, [U32, U32, PTR])
        self._storage = C.create_string_buffer(1024)
        first = self.api.MIDIPacketListInit(self._storage)
        self._packet_offset = first - C.addressof(self._storage)
        self._aligned = platform.machine().lower() in ("arm64", "aarch64")

    @staticmethod
    def check(status, operation):
        if status:
            raise RuntimeError(f"{operation}: OSStatus {status}")

    def string(self, text):
        result = self.cf.CFStringCreateWithCString(None, text.encode(), 0x08000100)
        if not result:
            raise RuntimeError("CFString allocation failed")
        return result

    def ports(self, input):
        count = self.api.MIDIGetNumberOfSources() if input else self.api.MIDIGetNumberOfDestinations()
        endpoint = self.api.MIDIGetSource if input else self.api.MIDIGetDestination
        name_key = PTR.in_dll(self.api, "kMIDIPropertyDisplayName")
        offline_key = PTR.in_dll(self.api, "kMIDIPropertyOffline")
        result = []
        for index in range(count):
            ref, value = endpoint(index), PTR()
            offline = C.c_int32()
            self.check(self.api.MIDIObjectGetIntegerProperty(ref, offline_key, C.byref(offline)), "Read endpoint availability")
            if offline.value:
                continue
            self.check(self.api.MIDIObjectGetStringProperty(ref, name_key, C.byref(value)), "Read endpoint name")
            try:
                text = C.create_string_buffer(1024)
                if not self.cf.CFStringGetCString(value, text, len(text), 0x08000100):
                    raise RuntimeError("Endpoint name cannot be decoded")
                result.append(Port(index, text.value.decode()))
            finally:
                self.cf.CFRelease(value)
        return result

    def open(self, input_port, output_port=None):
        name = self.string("BCR Python CC Diagnostic")
        try:
            self.check(self.api.MIDIClientCreate(name, None, None, C.byref(self.client)), "Create client")
            callback_type = C.CFUNCTYPE(None, PTR, PTR, PTR)
            def received(packet_list, refcon, source):
                try:
                    for packed in mac_cc_packets(packet_list, self._packet_offset, self._aligned):
                        self.events.put(packed)
                except Exception as error:
                    self.events.put(RuntimeError("CoreMIDI input callback: " + str(error)))
            self.callback = callback_type(received)
            self.check(self.api.MIDIInputPortCreate(self.client, name, C.cast(self.callback, PTR), None, C.byref(self.input)), "Open input")
            self.source = self.api.MIDIGetSource(input_port.id)
            self.check(self.api.MIDIPortConnectSource(self.input, self.source, None), "Connect input")
            if output_port:
                self.check(self.api.MIDIOutputPortCreate(self.client, name, C.byref(self.output)), "Open output")
                self.destination = self.api.MIDIGetDestination(output_port.id)
        finally:
            self.cf.CFRelease(name)

    def send(self, message):
        if self.output_api != "legacy":
            protocol = 1 if self.output_api == "ump1" else 2
            words = ump_cc(message, protocol) * self.packet_repeats
            data = (U32 * len(words))(*words)
            packet = self.api.MIDIEventListInit(self._storage, protocol)
            if not self.api.MIDIEventListAdd(self._storage, len(self._storage), packet, 0, len(words), data):
                raise RuntimeError("Cannot create UMP event list")
            self.check(self.api.MIDISendEventList(self.output, self.destination, self._storage), "Send UMP CC")
            return
        packed = message.packed()
        raw = bytes([packed & 255, packed >> 8 & 255, packed >> 16 & 255]) * self.packet_repeats
        data = (C.c_ubyte * len(raw)).from_buffer_copy(raw)
        packet = self.api.MIDIPacketListInit(self._storage)
        added = self.api.MIDIPacketListAdd(self._storage, len(self._storage), packet, 0, len(raw), data)
        if not added:
            raise RuntimeError("Cannot create MIDI packet")
        self.check(self.api.MIDISend(self.output, self.destination, self._storage), "Send CC")

    def close(self):
        errors = []
        operations = []
        if self.input.value and self.source:
            operations.append((self.api.MIDIPortDisconnectSource, (self.input, self.source), "Disconnect input"))
        if self.input.value:
            operations.append((self.api.MIDIPortDispose, (self.input,), "Close input"))
        if self.output.value:
            operations.append((self.api.MIDIPortDispose, (self.output,), "Close output"))
        if self.client.value:
            operations.append((self.api.MIDIClientDispose, (self.client,), "Close client"))
        for function, arguments, operation in operations:
            try:
                self.check(function(*arguments), operation)
            except RuntimeError as error:
                errors.append(str(error))
        if errors:
            _KEEPALIVE.append(self)
            raise RuntimeError("; ".join(errors))


def read_cc(backend, timeout=0.05):
    event = backend.events.read(timeout)
    if isinstance(event, Exception):
        raise event
    return CC.unpack(event) if event is not None else None


def learn(backend, seconds):
    deadline, last_at, learned = time.monotonic() + seconds, None, None
    while time.monotonic() < deadline:
        message = read_cc(backend)
        if message:
            print(f"RX CC: channel={message.channel} controller={message.controller} value={message.value}", flush=True)
            if message.controller in {0, 6, 32, 38, 96, 97, 98, 99, 100, 101} or message.controller >= 120:
                raise ValueError("Use an ordinary absolute 7-bit CC encoder; bank/RPN/NRPN/channel-mode CC is excluded.")
            if learned and (message.channel, message.controller) != (learned.channel, learned.controller):
                raise ValueError("More than one CC/channel received; turn only one absolute 7-bit CC encoder.")
            learned, last_at = message, time.monotonic()
        if last_at is not None and time.monotonic() - last_at >= 1:
            return learned
    if learned:
        return learned
    raise RuntimeError("No CC received before timeout. No output sent.")


def sweep(backend, learned, wait=time.sleep):
    sent = False
    try:
        for value in [0, 32, 64, 96, 127]:
            sent = True  # Also attempt restoration if the native send raises midway.
            backend.send(CC(learned.channel, learned.controller, value))
            print(f"TX CC: channel={learned.channel} controller={learned.controller} value={value}", flush=True)
            wait(1.5)
    finally:
        if sent:
            backend.send(learned)
            print(f"Restore message sent: value={learned.value} (hardware display not acknowledged)", flush=True)


def mac_virtual_self_test(packet_repeats=1, output_api="legacy"):
    owner, backend = MacMIDI(), MacMIDI(packet_repeats=packet_repeats, output_api=output_api)
    name = owner.string("Console Python Virtual Diagnostic")
    received = queue.Queue()
    callback_type = C.CFUNCTYPE(None, PTR, PTR, PTR)
    def callback(packet_list, refcon, connection):
        try:
            for packed in mac_cc_packets(packet_list, owner._packet_offset, owner._aligned):
                received.put_nowait(packed)
        except Exception as error:
            received.put_nowait(error)
    retained_callback = callback_type(callback)
    try:
        owner.check(owner.api.MIDIClientCreate(name, None, None, C.byref(owner.client)), "Create virtual client")
        source, destination = U32(), U32()
        create_source = bind(owner.api, "MIDISourceCreate", C.c_int32, [U32, PTR, C.POINTER(U32)])
        create_destination = bind(owner.api, "MIDIDestinationCreate", C.c_int32, [U32, PTR, PTR, PTR, C.POINTER(U32)])
        owner.check(create_source(owner.client, name, C.byref(source)), "Create virtual source")
        owner.check(create_destination(owner.client, name, C.cast(retained_callback, PTR), None, C.byref(destination)), "Create virtual destination")
        input_index = next(i for i in range(owner.api.MIDIGetNumberOfSources()) if owner.api.MIDIGetSource(i) == source.value)
        output_index = next(i for i in range(owner.api.MIDIGetNumberOfDestinations()) if owner.api.MIDIGetDestination(i) == destination.value)
        backend.open(Port(input_index, "virtual source"), Port(output_index, "virtual destination"))
        for value in [0, 32, 64, 96, 127]:
            expected = CC(1, 8, value)
            backend.send(expected)
            for _ in range(packet_repeats):
                if received.get(timeout=2) != expected.packed():
                    raise RuntimeError("Virtual output byte mismatch")
        data = (C.c_ubyte * 3)(0xB2, 9, 64)
        packet = owner.api.MIDIPacketListInit(owner._storage)
        if not owner.api.MIDIPacketListAdd(owner._storage, len(owner._storage), packet, 0, 3, data):
            raise RuntimeError("Virtual input packet construction failed")
        inject = bind(owner.api, "MIDIReceived", C.c_int32, [U32, PTR])
        owner.check(inject(source, owner._storage), "Inject virtual input")
        if read_cc(backend, timeout=2) != CC(3, 9, 64):
            raise RuntimeError("Virtual input callback mismatch")
        print("Native CoreMIDI virtual input/output self-test passed; no physical destination used.")
    finally:
        try:
            backend.close()
        finally:
            owner.close()
            owner.cf.CFRelease(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["list", "monitor", "test"], default="list")
    parser.add_argument("--self-test", action="store_true", help="macOS virtual input/output check; no physical sends")
    parser.add_argument("--mac-api", choices=["legacy", "ump1", "ump2"], default="legacy", help="macOS output API for controlled comparisons")
    parser.add_argument("--packet-repeats", type=int, default=1, help="macOS diagnostic: repeat identical CC 1..16 times in one packet")
    parser.add_argument("--allow-other-device", action="store_true", help="allow an explicitly selected DIN/network MIDI interface connected to the BCR")
    parser.add_argument("--input", type=int)
    parser.add_argument("--output", type=int)
    parser.add_argument("--seconds", type=int, default=120)
    args = parser.parse_args()
    if not 1 <= args.packet_repeats <= 16:
        parser.error("--packet-repeats must be 1..16")
    if sys.platform != "darwin" and (args.packet_repeats != 1 or args.mac_api != "legacy"):
        parser.error("--packet-repeats and --mac-api are macOS diagnostics")
    if args.self_test:
        if sys.platform != "darwin":
            parser.error("--self-test uses macOS virtual endpoints; run the offline Python tests on other systems")
        mac_virtual_self_test(args.packet_repeats, args.mac_api)
        return
    if not 1 <= args.seconds <= 300:
        parser.error("--seconds must be 1..300")
    if sys.platform == "win32":
        backend = WinMM()
    elif sys.platform == "darwin":
        backend = MacMIDI(packet_repeats=args.packet_repeats, output_api=args.mac_api)
    else:
        parser.error("Native MIDI supports Windows and macOS only")
    try:
        inputs, outputs = backend.ports(True), backend.ports(False)
        for title, ports in [("INPUTS", inputs), ("OUTPUTS", outputs)]:
            print(title)
            for port in ports:
                print(f"  [{port.id}] {port.name}")
        if args.mode == "list":
            return
        input_port = resolve(inputs, args.input, "input")
        output_port = resolve(outputs, args.output, "output") if args.mode == "test" else None
        if output_port:
            validate_output(output_port, args.allow_other_device, args.input, args.output)
        backend.open(input_port, output_port)
        print("Input:", input_port.name)
        if sys.platform == "darwin":
            print(f"CoreMIDI API: {args.mac_api}; packet repeats: {args.packet_repeats}")
        if output_port:
            print("Output:", output_port.name)
        if args.mode == "monitor":
            deadline = time.monotonic() + args.seconds
            while time.monotonic() < deadline:
                message = read_cc(backend)
                if message:
                    print(f"RX CC: channel={message.channel} controller={message.controller} value={message.value}", flush=True)
            return
        print("READY: turn ONE absolute 7-bit CC encoder, then stop and watch the SAME ring.", flush=True)
        print("No SysEx/preset writes. Five values will be sent after input stops for one second.", flush=True)
        learned = learn(backend, args.seconds)
        print(f"Learned channel={learned.channel}, CC={learned.controller}, last value={learned.value}.", flush=True)
        time.sleep(2)
        sweep(backend, learned)
        print("PASS requires seeing the same ring follow five positions. Native send success is not hardware acknowledgement.")
    finally:
        backend.close()
        if backend.events.dropped:
            raise RuntimeError(f"Input overflow: {backend.events.dropped} messages dropped; test incomplete")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        print("ERROR:", error, file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        raise SystemExit(130)
