import BCRFoundation
import Foundation
import enum ParameterOutputPlugin.OSCCodec

public enum OSCCodec {
    public static func encode(_ packet: OSCPacket) throws
        -> Data { try withLegacyOutputErrors { try ParameterOutputPlugin.OSCCodec.encode(packet) } }
    public static func decode(_ data: Data) throws
        -> OSCPacket { try withLegacyOutputErrors { try ParameterOutputPlugin.OSCCodec.decode(data) } }
    public static func immediateMessages(_ packet: OSCPacket) throws
        -> [OSCMessage] { try withLegacyOutputErrors { try ParameterOutputPlugin.OSCCodec.immediateMessages(packet) } }
    public static func parameterAddress(_ id: ParameterID,
                                        prefix: String = "/bcr/param/") -> String
    { ParameterOutputPlugin.OSCCodec.parameterAddress(
        id,
        prefix: prefix
    ) }
    public static func parameterID(_ address: String,
                                   prefix: String = "/bcr/state/") throws
        -> ParameterID
    { try withLegacyOutputErrors { try ParameterOutputPlugin.OSCCodec.parameterID(
        address,
        prefix: prefix
    ) } }
}
