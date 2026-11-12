import CoreFoundation
import Darwin
import Foundation

/// Host-issued identities for the one authenticated bearer and the two host-owned event sources.
/// This private record contains no credential, credential hash, or client-selected identity.
public struct SurfaceControlPrincipals: Equatable, Sendable {
    public let remoteWriterID: String
    public let interfaceWriterID: String
    public let systemWriterID: String

    public struct RecordError: Error, LocalizedError {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    public init() {
        func fresh() -> String {
            var random = SystemRandomNumberGenerator()
            return (0 ..< 16).map { _ in
                String(format: "%02x", UInt8.random(in: .min ... .max, using: &random))
            }.joined()
        }
        remoteWriterID = fresh()
        var interfaceID = fresh()
        while interfaceID == remoteWriterID { interfaceID = fresh() }
        interfaceWriterID = interfaceID
        var systemID = fresh()
        while systemID == remoteWriterID || systemID == interfaceID { systemID = fresh() }
        systemWriterID = systemID
    }

    private init(remote: String, interface: String, system: String) {
        remoteWriterID = remote; interfaceWriterID = interface; systemWriterID = system
    }

    private static let fields: Set<String> = [
        "schema_version", "remote_writer_id", "interface_writer_id", "system_writer_id"
    ]

    private var encoded: Data {
        get throws {
            try JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "remote_writer_id": remoteWriterID,
                "interface_writer_id": interfaceWriterID, "system_writer_id": systemWriterID
            ], options: [.sortedKeys])
        }
    }

    private static func decode(_ data: Data) throws -> Self {
        // Foundation overwrites duplicate keys. Decode escaped names before checking uniqueness.
        let text = String(decoding: data, as: UTF8.self)
        let expression = try NSRegularExpression(pattern: #"("(?:[^"\\]|\\.)*")\s*:"#)
        var keys: Set<String> = []
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let keyRange = Range(match.range(at: 1), in: text)!
            let key = try JSONDecoder().decode(String.self, from: Data(text[keyRange].utf8))
            guard keys.insert(key).inserted else {
                throw RecordError(reason: "Duplicate private surface principal record key")
            }
            if key == "schema_version" {
                let end = Range(match.range, in: text)!.upperBound
                let value = text[end...].drop(while: \.isWhitespace)
                guard value.first == "1", let next = value.dropFirst().first,
                      next == "," || next == "}" || next.isWhitespace
                else {
                    throw RecordError(reason: "Principal schema version must be the integer 1")
                }
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == fields,
              let version = object["schema_version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1
        else { throw RecordError(reason: "Invalid private surface principal record schema") }
        func id(_ key: String) throws -> String {
            guard let value = object[key] as? String, (32 ... 128).contains(value.utf8.count),
                  value.utf8.count.isMultiple(of: 2),
                  value.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
            else { throw RecordError(reason: "Invalid private surface principal identity") }
            return value
        }
        let result = try Self(remote: id("remote_writer_id"), interface: id("interface_writer_id"),
                              system: id("system_writer_id"))
        guard Set([result.remoteWriterID, result.interfaceWriterID, result.systemWriterID]).count == 3 else {
            throw RecordError(reason: "Private surface principal identities must be distinct")
        }
        return result
    }

    /// Only call after the process's sole bearer credential has been validated. A supplied path is
    /// explicit host administration, never request data. Missing files are create-only; a race fails.
    public static func loadOrCreate(at url: URL) throws -> Self {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600,
                  info.st_size > 0, info.st_size <= 4096
            else { throw RecordError(reason: "Principal record must be an owned regular 0600 file") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            guard let data = try handle.read(upToCount: 4097), data.count <= 4096 else {
                throw RecordError(reason: "Principal record exceeds its size bound")
            }
            return try decode(data)
        }
        guard errno == ENOENT else { throw RecordError(reason: "Cannot safely open private surface principal record") }
        let value = Self()
        let data = try value.encoded
        // Publish a complete record atomically with a no-replace hard link on the same filesystem.
        let temporary = url.deletingLastPathComponent().appending(path: ".surface-principal-" + UUID().uuidString)
        let created = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard created >= 0 else {
            throw RecordError(reason: "Cannot create private surface principal record without replacing a file")
        }
        defer { close(created); unlink(temporary.path) }
        guard fchmod(created, mode_t(0o600)) == 0 else {
            throw RecordError(reason: "Cannot protect private surface principal record")
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(created, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw RecordError(reason: "Cannot write private surface principal record") }
                offset += count
            }
        }
        guard fsync(created) == 0 else { throw RecordError(reason: "Cannot persist private surface principal record") }
        guard link(temporary.path, url.path) == 0 else {
            throw RecordError(reason: "Cannot publish private surface principal record without replacing a file")
        }
        return value
    }
}
