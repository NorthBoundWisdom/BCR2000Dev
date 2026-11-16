import Foundation

/// Optional process-owner provisioning. Credentials never become RPC arguments or persisted identities.
public struct SurfaceClientCredentials: Sendable {
    public let owner: String
    public let operatorToken: String
    public let display: String
    public let additionalDisplays: [String]
    public private(set) var operatorWriterID: String
    public private(set) var displayWriterID: String
    public private(set) var additionalDisplayWriterIDs: [String]
    public var hasAdditionalDisplays: Bool { !additionalDisplays.isEmpty }
    public var displayCredentials: [(token: String, writerID: String)] {
        [(display, displayWriterID)] + zip(additionalDisplays, additionalDisplayWriterIDs).map { ($0, $1) }
    }

    public struct Invalid: Error { public init() {} }

    private static func identity() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Exclude both loaded legacy principals and every other issued role, including extra displays.
    public mutating func excludeWriterIDs(_ excluded: Set<String>) {
        var used = excluded
        while used.contains(operatorWriterID) { operatorWriterID = Self.identity() }
        used.insert(operatorWriterID)
        while used.contains(displayWriterID) { displayWriterID = Self.identity() }
        used.insert(displayWriterID)
        for index in additionalDisplayWriterIDs.indices {
            while used
                .contains(additionalDisplayWriterIDs[index]) { additionalDisplayWriterIDs[index] = Self.identity() }
            used.insert(additionalDisplayWriterIDs[index])
        }
    }

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= 2048,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Invalid() }
        let required: Set<String> = ["owner", "operator", "display"]
        let extended = object.keys.contains("displays")
        guard Set(object.keys) == (extended ? required.union(["displays"]) : required),
              data.count <= (extended ? 2048 : 512),
              let owner = object["owner"] as? String,
              let operatorToken = object["operator"] as? String,
              let display = object["display"] as? String else { throw Invalid() }
        let additional: [String]
        if extended {
            guard let values = object["displays"] as? [String],
                  (1 ... 7).contains(values.count) else { throw Invalid() }
            additional = values
        } else { additional = [] }
        // Every accepted value is hex; key-count validation also rejects escaped duplicate keys.
        let expression = try NSRegularExpression(pattern: #"\"(?:[^\"\\]|\\.)*\"\s*:"#)
        let text = String(decoding: data, as: UTF8.self)
        guard expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == object.count else {
            throw Invalid()
        }
        let values = [owner, operatorToken, display] + additional
        guard Set(values).count == values.count, values.allSatisfy({ value in
            value.utf8.count == 64 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
        }) else { throw Invalid() }
        self.owner = owner; self.operatorToken = operatorToken; self.display = display
        additionalDisplays = additional
        operatorWriterID = Self.identity(); displayWriterID = Self.identity()
        additionalDisplayWriterIDs = additional.map { _ in Self.identity() }
        excludeWriterIDs([])
    }
}
