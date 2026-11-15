import Foundation

/// Optional process-owner provisioning. Credentials never become RPC arguments or persisted identities.
public struct SurfaceClientCredentials: Sendable {
    public let owner: String
    public let operatorToken: String
    public let display: String
    public private(set) var operatorWriterID: String
    public private(set) var displayWriterID: String

    public struct Invalid: Error { public init() {} }

    /// Exclude the loaded legacy principal namespace explicitly, rather than relying on random collision odds.
    public mutating func excludeWriterIDs(_ excluded: Set<String>) {
        while excluded.contains(operatorWriterID) {
            operatorWriterID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        while excluded.contains(displayWriterID) || displayWriterID == operatorWriterID {
            displayWriterID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    }

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= 512,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(object.keys) == ["owner", "operator", "display"] else { throw Invalid() }
        // All valid values are hex strings, so no embedded JSON syntax can masquerade as a key.
        let expression = try NSRegularExpression(pattern: #"\"(?:[^\"\\]|\\.)*\"\s*:"#)
        let text = String(decoding: data, as: UTF8.self)
        guard expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 3 else {
            throw Invalid()
        }
        let values = [object["owner"]!, object["operator"]!, object["display"]!]
        guard Set(values).count == 3, values.allSatisfy({ value in
            value.utf8.count == 64 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
        }) else { throw Invalid() }
        owner = values[0]; operatorToken = values[1]; display = values[2]
        operatorWriterID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var second = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        while second ==
            operatorWriterID { second = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        displayWriterID = second
    }
}
