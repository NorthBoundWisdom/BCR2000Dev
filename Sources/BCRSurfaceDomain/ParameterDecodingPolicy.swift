import Foundation

/// Compatibility adapters may inject historical protection; the domain knows no reserved names.
public enum ParameterDecodingPolicy {
    public static let legacyProtectedIDs = CodingUserInfoKey(rawValue: "bcr.legacyProtectedParameterIDs")!
}
