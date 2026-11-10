import Foundation
import IOKit
import IOKit.usb

// One target-only software unplug/replug experiment; no capture/seize, firmware or MIDI commands.
func property(_ service: io_service_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func reenumerate(_ service: io_service_t) -> [String: Any] {
    let dc = CFUUIDCreateFromString(nil, "9DC7B780-9EC0-11D4-A54F-000A27052861" as CFString)!
    let pc = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)!
    let ic = CFUUIDCreateFromString(nil, "3C9EE1EB-2402-11B2-8E7E-000A27801E86" as CFString)!
    var p: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    let created = IOCreatePlugInInterfaceForService(service, dc, pc, &p, &score)
    guard created == 0, let p, let pf = p.pointee else { return ["created": created] }
    defer { _ = IODestroyPlugInInterface(p) }
    var raw: UnsafeMutableRawPointer?
    let queried = pf.pointee.QueryInterface(p, CFUUIDGetUUIDBytes(ic), &raw)
    guard queried == 0, let raw else { return ["queried": queried] }
    let d = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface187>?.self)
    guard let df = d.pointee else { return ["error": "null interface"] }
    defer { _ = df.pointee.Release(d) }
    let opened = df.pointee.USBDeviceOpen(d)
    guard opened == 0 else { return ["openStatus": opened, "reenumerationAttempted": false] }
    let result = df.pointee.USBDeviceReEnumerate(d, 0)
    let closed = df.pointee.USBDeviceClose(d)
    return [
        "openStatus": opened,
        "reenumerationStatus": result,
        "closeStatus": closed,
        "reenumerationAttempted": true,
        "firmwareWrites": false
    ]
}

struct USBIdentity: Sendable {
    let vendor: Int
    let product: Int
    let release: Int
    var isBCR: Bool { vendor == 0x1397 && product == 0x00BC && release == 0x0100 }
}

func selectedTarget(_ identities: [USBIdentity]) -> Int? {
    let selected = identities.indices.filter { identities[$0].isBCR }
    return selected.count == 1 ? selected[0] : nil
}

if CommandLine.arguments.dropFirst() == ["--self-test"] {
    let target = USBIdentity(vendor: 0x1397, product: 0x00BC, release: 0x0100)
    precondition(selectedTarget([]) == nil)
    precondition(selectedTarget([target]) == 0)
    precondition(selectedTarget([target, target]) == nil)
    precondition(selectedTarget([USBIdentity(vendor: 1, product: 0x00BC, release: 0x0100)]) == nil)
    precondition(selectedTarget([USBIdentity(vendor: 0x1397, product: 0x00BC, release: 0x0200)]) == nil)
    print("Target selection self-test passed; no USB access.")
    exit(0)
}

guard CommandLine.arguments.dropFirst() == ["--reenumerate"] else {
    print("Explicit --reenumerate required; or --self-test for no USB access.")
    exit(64)
}

var iterator: io_iterator_t = 0
let matched = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
guard matched == 0 else { exit(2) }
var services: [io_service_t] = []
var identities: [USBIdentity] = []
while true {
    let service = IOIteratorNext(iterator)
    if service == 0 { break }
    services.append(service)
    identities.append(USBIdentity(
        vendor: (property(service, "idVendor") as? NSNumber)?.intValue ?? -1,
        product: (property(service, "idProduct") as? NSNumber)?.intValue ?? -1,
        release: (property(service, "bcdDevice") as? NSNumber)?.intValue ?? -1
    ))
}

IOObjectRelease(iterator)
defer { for service in services { IOObjectRelease(service) } }
guard let selected = selectedTarget(identities) else {
    print("Need exactly one supported BCR; no reenumeration attempted.")
    exit(2)
}

let report = reenumerate(services[selected])
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
if (report["reenumerationStatus"] as? Int32) != 0 { exit(2) }
