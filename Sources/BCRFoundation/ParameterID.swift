@_exported import struct SurfacePluginContracts.ParameterID

/// Preserve the old single-string Codable identity and source constructors.
public typealias ParameterID = SurfacePluginContracts.ParameterID

extension SurfacePluginContracts.ParameterID: @retroactive Comparable, @retroactive CustomStringConvertible {
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
