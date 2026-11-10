import Foundation
import IOKit
import IOKit.usb

// Read cached configuration bytes. Deliberately never opens/seizes the device,
// selects a configuration, resets it, changes pipe policy, or sends data.
func property(_ service: io_service_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func cachedDescriptor(_ service: io_service_t) -> [String: Any] {
    let deviceClientUUID = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
    let pluginUUID = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!
    let deviceInterfaceUUID = CFUUIDCreateFromString(nil, "5C8187D0-9EF3-11D4-8B45-000A27052861" as CFString)!
    var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    let created = IOCreatePlugInInterfaceForService(service, deviceClientUUID, pluginUUID, &plugin, &score)
    guard created == kIOReturnSuccess, let plugin, let functions = plugin.pointee else {
        return ["status": "unavailable", "operation": "Create descriptor reader", "code": created]
    }
    defer { _ = IODestroyPlugInInterface(plugin) }
    var raw: UnsafeMutableRawPointer?
    let queried = functions.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(deviceInterfaceUUID), &raw)
    guard queried == 0, let raw else {
        return ["status": "unavailable", "operation": "Query device interface", "code": queried]
    }
    let device = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
    guard let interface = device.pointee else { return ["status": "error", "reason": "Null device interface"] }
    defer { _ = interface.pointee.Release(device) }
    var descriptor: IOUSBConfigurationDescriptorPtr?
    let result = interface.pointee.GetConfigurationDescriptorPtr(device, 0, &descriptor)
    guard result == kIOReturnSuccess, let descriptor else {
        return ["status": "unavailable", "operation": "Read cached configuration", "code": result]
    }
    let bytes = UnsafeRawPointer(descriptor).assumingMemoryBound(to: UInt8.self)
    let length = Int(bytes[2]) | Int(bytes[3]) << 8
    guard length >= 9, length <= 8192, bytes[0] == 9, bytes[1] == 2 else {
        return ["status": "error", "reason": "Invalid cached configuration length/type"]
    }
    let data = Data(bytes: bytes, count: length)
    var configuration: UInt8 = 0
    let configurationStatus = interface.pointee.GetConfiguration(device, &configuration)
    return ["status": "ok", "source": "cached GetConfigurationDescriptorPtr",
            "currentConfiguration": configurationStatus == kIOReturnSuccess ? Int(configuration) : -1,
            "bytes": length, "configurationHex": data.map { String(format: "%02x", $0) }.joined()]
}

var targets: [[String: Any]] = []
var failures: [[String: Any]] = []
var seen = Set<UInt64>()
for className in [kIOUSBDeviceClassName, "IOUSBHostDevice"] {
    var iterator: io_iterator_t = 0
    let matched = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
    guard matched == kIOReturnSuccess else {
        failures.append(["operation": "Match USB device services", "class": className, "code": matched])
        continue
    }
    defer { IOObjectRelease(iterator) }
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        guard (property(service, "idVendor") as? NSNumber)?.intValue == 0x1397,
              (property(service, "idProduct") as? NSNumber)?.intValue == 0x00BC else { continue }
        var identifier: UInt64 = 0
        let idStatus = IORegistryEntryGetRegistryEntryID(service, &identifier)
        if idStatus == kIOReturnSuccess, !seen.insert(identifier).inserted { continue }
        var target: [String: Any] = ["vendor": 0x1397, "product": 0x00BC, "matchingClass": className,
                                     "cachedConfiguration": cachedDescriptor(service)]
        for key in ["USBSpeed", "bcdUSB", "bcdDevice", "bConfigurationValue"] {
            if let value = property(service, key) as? NSNumber { target[key] = value }
        }
        targets.append(target)
    }
}
let report: [String: Any] = ["schemaVersion": 1, "readOnly": true, "targets": targets, "errors": failures]
let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
FileHandle.standardOutput.write(encoded)
FileHandle.standardOutput.write(Data([10]))
