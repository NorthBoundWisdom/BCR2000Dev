import BCRSurfaceDomain
import Foundation

/// Process-local proof only. A locked working copy may keep its proven number through
/// an approved edit on the same uninterrupted route; disk profiles never supply this proof.
struct PresetNumberEvidence {
    let number: Int
    let route: PresetRestoreRoute
    let name: String
    let candidates: [Int]
    let device: UInt8
    let definition: [String]
    let locked: Bool
    let originalDefinition: [String]

    init?(number: Int?, dump: Data, names: BCRPresetNames, route: MIDIConnectionSnapshot,
          originalDefinition: [String]? = nil) throws
    {
        let profile = try BCRDisplayProfile.read(fromPresetDump: dump)
        guard let number, let name = names.temporaryName,
              names.candidates.contains(number), profile.name == name else { return nil }
        self.number = number
        self.route = PresetRestoreRoute(route)
        self.name = name
        candidates = names.candidates
        device = try BCRPresetAlignment.deviceIdentifier(of: dump)
        definition = try BCRPresetAlignment.identityLines(of: dump)
        locked = profile.locked == true
        self.originalDefinition = originalDefinition ?? definition
    }

    func matches(_ names: BCRPresetNames, on route: MIDIConnectionSnapshot) -> Bool {
        self.route.matches(route) && name == names.temporaryName && candidates == names.candidates
    }

    func matches(_ dump: Data, names: BCRPresetNames, on route: MIDIConnectionSnapshot) throws -> Bool {
        guard matches(names, on: route) else { return false }
        let currentDevice = try BCRPresetAlignment.deviceIdentifier(of: dump)
        let currentDefinition = try BCRPresetAlignment.identityLines(of: dump)
        return device == currentDevice && definition == currentDefinition
    }
}
