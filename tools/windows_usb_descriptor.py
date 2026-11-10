#!/usr/bin/env python3
"""Read BCR2000 USB configuration descriptors on Windows, standard library only.

Uses Microsoft USBView-style hub GET queries. No USB data output, configuration
selection, driver installation, reset, firmware or preset operations.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
import struct
import sys
import uuid

U32, PTR, UPTR = C.c_uint32, C.c_void_p, C.c_size_t
GET_NODE_INFORMATION = 0x220408
GET_CONNECTION_INFORMATION = 0x220448
GET_DESCRIPTOR = 0x220410
BCR_VENDOR, BCR_PRODUCT = 0x1397, 0x00BC


class GUID(C.Structure):
    _fields_ = [("data1", U32), ("data2", C.c_uint16), ("data3", C.c_uint16), ("data4", C.c_ubyte * 8)]


class IFACE(C.Structure):
    _fields_ = [("size", U32), ("guid", GUID), ("flags", U32), ("reserved", UPTR)]


def bind(library, name, result, arguments):
    function = getattr(library, name)
    function.restype, function.argtypes = result, arguments
    return function


def hubs(kernel, setup):
    guid = GUID.from_buffer_copy(uuid.UUID("f18a0e88-c30c-11d0-8815-00a0c906bed8").bytes_le)
    devices = setup.SetupDiGetClassDevsW(C.byref(guid), None, None, 0x12)
    if devices == PTR(-1).value:
        raise C.WinError(C.get_last_error())
    try:
        index = 0
        while True:
            item = IFACE(size=C.sizeof(IFACE))
            if not setup.SetupDiEnumDeviceInterfaces(devices, None, C.byref(guid), index, C.byref(item)):
                if C.get_last_error() == 259:  # ERROR_NO_MORE_ITEMS
                    break
                raise C.WinError(C.get_last_error())
            needed = U32()
            setup.SetupDiGetDeviceInterfaceDetailW(devices, C.byref(item), None, 0, C.byref(needed), None)
            if not needed.value:
                raise C.WinError(C.get_last_error())
            data = C.create_string_buffer(needed.value)
            U32.from_buffer(data).value = 8 if C.sizeof(PTR) == 8 else 6
            if not setup.SetupDiGetDeviceInterfaceDetailW(devices, C.byref(item), data, len(data), C.byref(needed), None):
                raise C.WinError(C.get_last_error())
            yield C.wstring_at(C.addressof(data) + 4)
            index += 1
    finally:
        setup.SetupDiDestroyDeviceInfoList(devices)


def ioctl(kernel, handle, code, data):
    received = U32()
    if not kernel.DeviceIoControl(handle, code, data, len(data), data, len(data), C.byref(received), None):
        return None, C.get_last_error()
    return bytes(data)[:received.value], None


def descriptor(kernel, handle, port, length):
    data = C.create_string_buffer(12 + length)
    # USB_DESCRIPTOR_REQUEST: connection index followed by a GET_DESCRIPTOR setup.
    struct.pack_into("<IBBHHH", data, 0, port, 0x80, 6, 0x0200, 0, length)
    result, error = ioctl(kernel, handle, GET_DESCRIPTOR, data)
    if error:
        raise OSError(error, "Read configuration descriptor failed")
    return result[12:]


def parse(data):
    if len(data) < 9 or data[0] != 9 or data[1] != 2 or int.from_bytes(data[2:4], "little") != len(data):
        raise ValueError("Invalid or incomplete configuration descriptor")
    items, index = [], 0
    while index < len(data):
        length = data[index]
        if length < 2 or index + length > len(data):
            raise ValueError("Truncated USB descriptor")
        item = data[index:index + length]
        kind = item[1]
        if kind == 4:
            if length < 9:
                raise ValueError("Short interface descriptor")
            items.append({"interface": item[2], "alternate": item[3], "endpoints": item[4],
                          "class": item[5], "subclass": item[6], "protocol": item[7]})
        elif kind == 5:
            if length < 7:
                raise ValueError("Short endpoint descriptor")
            items.append({"endpointAddress": hex(item[2]), "attributes": item[3],
                          "maxPacket": int.from_bytes(item[4:6], "little"), "interval": item[6]})
        elif kind == 0x25:
            items.append({"classEndpoint": list(item)})
        elif kind == 0x24:
            items.append({"classInterface": list(item)})
        index += length
    return items


def full_speed_bulk_warnings(descriptors, speed):
    if speed != 1:  # USB_DEVICE_SPEED: Full Speed.
        return []
    return [
        {"endpoint": item["endpointAddress"], "declaredMaxPacket": item["maxPacket"],
         "reason": "Full-speed bulk endpoint declares a size outside 8/16/32/64; host compatibility needs verification"}
        for item in descriptors
        if "endpointAddress" in item and item["attributes"] & 3 == 2
        and item["maxPacket"] not in (8, 16, 32, 64)
    ]


def collect():
    kernel = C.WinDLL("kernel32", use_last_error=True)
    setup = C.WinDLL("setupapi", use_last_error=True)
    bind(setup, "SetupDiGetClassDevsW", PTR, [C.POINTER(GUID), C.c_wchar_p, PTR, U32])
    bind(setup, "SetupDiEnumDeviceInterfaces", C.c_int, [PTR, PTR, C.POINTER(GUID), U32, C.POINTER(IFACE)])
    bind(setup, "SetupDiGetDeviceInterfaceDetailW", C.c_int, [PTR, C.POINTER(IFACE), PTR, U32, C.POINTER(U32), PTR])
    bind(setup, "SetupDiDestroyDeviceInfoList", C.c_int, [PTR])
    bind(kernel, "CreateFileW", PTR, [C.c_wchar_p, U32, U32, PTR, U32, U32, PTR])
    bind(kernel, "CloseHandle", C.c_int, [PTR])
    bind(kernel, "DeviceIoControl", C.c_int, [PTR, U32, PTR, U32, PTR, U32, C.POINTER(U32), PTR])
    report = {"targets": [], "hubAccessErrors": []}
    for path in hubs(kernel, setup):
        handle = kernel.CreateFileW(path, 0x40000000, 3, None, 3, 0, None)
        if handle == PTR(-1).value:
            report["hubAccessErrors"].append(C.get_last_error())
            continue
        try:
            info, error = ioctl(kernel, handle, GET_NODE_INFORMATION, C.create_string_buffer(1024))
            if error:
                report["hubAccessErrors"].append(error)
                continue
            if len(info) < 7:
                continue
            for port in range(1, info[6] + 1):
                query = C.create_string_buffer(4096)
                struct.pack_into("<I", query, 0, port)
                connection, error = ioctl(kernel, handle, GET_CONNECTION_INFORMATION, query)
                if error or len(connection) < 24:
                    continue
                vendor, product = struct.unpack_from("<HH", connection, 12)
                if (vendor, product) != (BCR_VENDOR, BCR_PRODUCT):
                    continue
                header = descriptor(kernel, handle, port, 9)
                if len(header) < 9:
                    raise ValueError("Truncated configuration header")
                total = struct.unpack_from("<H", header, 2)[0]
                if not 9 <= total <= 8192:
                    raise ValueError("Invalid configuration length")
                full = descriptor(kernel, handle, port, total)
                parsed = parse(full)
                report["targets"].append({
                    "vendor": hex(vendor), "product": hex(product),
                    "configuration": full[5], "currentConfiguration": connection[22],
                    "numConfigurations": connection[21], "configurationBytes": len(full),
                    "speedCode": connection[23], "usbVersionBcd": hex(struct.unpack_from("<H", connection, 6)[0]),
                    "descriptors": parsed,
                    "fullSpeedBulkSizeWarnings": full_speed_bulk_warnings(parsed, connection[23]),
                })
        finally:
            kernel.CloseHandle(handle)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("Native descriptor collection runs on Windows")
    report = collect()
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print("ERROR:", error, file=sys.stderr)
        raise SystemExit(1)
