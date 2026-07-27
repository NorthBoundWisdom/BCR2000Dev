import Foundation

public struct ControllerBinding: Hashable, Codable, Sendable, Identifiable {
    public let slotID: AgentSlotID
    public let control: MIDIControlID

    public var id: AgentSlotID { slotID }

    public init(slotID: AgentSlotID, control: MIDIControlID) {
        self.slotID = slotID
        self.control = control
    }
}

public struct ControllerProfile: Equatable, Codable, Sendable {
    /// Version 2 invalidates the MVP's initial auto-armed profiles. Those profiles could capture
    /// ordinary encoder movement; v2 mappings are only created after explicit user arming.
    public static let currentVersion = 2

    public var version: Int
    public var deviceName: String
    public private(set) var bindings: [ControllerBinding]

    public init(
        version: Int = ControllerProfile.currentVersion,
        deviceName: String = "BCR2000",
        bindings: [ControllerBinding] = []
    ) {
        self.version = version
        self.deviceName = deviceName
        self.bindings = bindings.sorted { $0.slotID < $1.slotID }
    }

    public var isComplete: Bool {
        Set(bindings.map(\.slotID)).count == 8
    }

    public var nextUnboundSlot: AgentSlotID? {
        let bound = Set(bindings.map(\.slotID))
        return (1...8).map(AgentSlotID.init).first { !bound.contains($0) }
    }

    public func binding(for slotID: AgentSlotID) -> ControllerBinding? {
        bindings.first { $0.slotID == slotID }
    }

    public func binding(for control: MIDIControlID) -> ControllerBinding? {
        bindings.first { $0.control == control }
    }

    @discardableResult
    public mutating func learn(_ control: MIDIControlID) -> ControllerBinding? {
        guard binding(for: control) == nil, let slotID = nextUnboundSlot else {
            return nil
        }
        let binding = ControllerBinding(slotID: slotID, control: control)
        bindings.append(binding)
        bindings.sort { $0.slotID < $1.slotID }
        return binding
    }

    public mutating func reset() {
        bindings.removeAll()
    }
}
