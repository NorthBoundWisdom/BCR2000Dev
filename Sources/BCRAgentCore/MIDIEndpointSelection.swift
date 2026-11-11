import Foundation

public struct MIDIEndpointDescriptor: Equatable, Identifiable, Sendable {
    public let id: Int32
    public let name: String
    public let availabilityKnown: Bool
    public init(id: Int32, name: String, availabilityKnown: Bool = true) {
        self.id = id; self.name = name; self.availabilityKnown = availabilityKnown
    }
}

public struct MIDIEndpointSelection: Codable, Equatable, Sendable {
    public var version = 1
    public var sourceID: Int32?
    public var destinationID: Int32?
    public init(sourceID: Int32? = nil, destinationID: Int32? = nil) {
        self.sourceID = sourceID; self.destinationID = destinationID
    }

    public func validate() throws {
        guard version == 1, sourceID != 0, destinationID != 0 else {
            throw MIDIEndpointSelectionError.invalidSettings
        }
    }
}

public enum MIDIEndpointSelectionError: Error, LocalizedError, Equatable, Sendable {
    case invalidSettings, missingSelectedEndpoint, missingPortOne
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: L10n.text("MIDI 端口设置版本或身份无效")
        case .missingSelectedEndpoint: L10n.text("手动选择的 MIDI 端口不可用，请重新选择；未自动切换其他端口")
        case .missingPortOne: L10n.text("未找到 BCR2000 Port 1，请连接设备或手动选择端口")
        }
    }
}

public enum MIDIEndpointPolicy {
    public static func resolve(_ endpoints: [MIDIEndpointDescriptor],
                               selectedID: Int32?) throws -> MIDIEndpointDescriptor
    {
        if let selectedID {
            guard let endpoint = endpoints.first(where: { $0.id == selectedID }) else {
                throw MIDIEndpointSelectionError.missingSelectedEndpoint
            }
            return endpoint
        }
        guard let endpoint = endpoints
            .first(where: {
                $0.name.localizedCaseInsensitiveContains("BCR2000") && $0.name
                    .localizedCaseInsensitiveContains("Port 1")
            })
        else {
            throw MIDIEndpointSelectionError.missingPortOne
        }
        return endpoint
    }
}
