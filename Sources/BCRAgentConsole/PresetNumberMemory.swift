import BCRPersistenceAdapter
import BCRSurfaceDomain
import CryptoKit
import Foundation

/// Definition-bound records include session-only confirmations, but only a content-unique
/// proof (or an approved edit carrying that proof) can restore a number across connections.
/// Every restore also re-reads and matches the route, name, candidates and working definition.
struct PresetNumberRecord: Codable, Equatable, Sendable {
    var route: PresetRestoreRoute
    var name: String
    var candidates: [Int]
    var definitionDigest: String
    var number: Int
    var recordedAt: Date
    /// Missing on legacy records: they remain readable but cannot restore a number.
    var uniquenessProven: Bool? = nil
}

struct PresetNumberMemory {
    static let maximumRecords = 16
    let store: JSONFileStore<[PresetNumberRecord]>

    static func digest(device: UInt8, definition: [String]) -> String {
        let bytes = Data([device]) + Data(definition.joined(separator: "\n").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of dump: Data) throws -> String {
        try digest(device: BCRPresetAlignment.deviceIdentifier(of: dump),
                   definition: BCRPresetAlignment.identityLines(of: dump))
    }

    /// The recorded number for exactly this working copy on this route, or nil.
    func number(for dump: Data, names: BCRPresetNames, route: MIDIConnectionSnapshot) throws -> Int? {
        // A corrupt cache means no proof, never a guessed number.
        guard let name = names.temporaryName, let records = try? store.load() else { return nil }
        let digest = try Self.digest(of: dump)
        return records.last {
            $0.uniquenessProven == true && $0.route.matches(route) && $0.name == name && $0.candidates == names
                .candidates
                && $0.definitionDigest == digest && names.candidates.contains($0.number)
        }?.number
    }

    /// Replaces any record for the same route/name/candidates/definition; keeps the newest few.
    func remember(_ evidence: PresetNumberEvidence, now: Date = .now) throws {
        let record = PresetNumberRecord(
            route: evidence.route, name: evidence.name, candidates: evidence.candidates,
            definitionDigest: Self.digest(device: evidence.device, definition: evidence.definition),
            number: evidence.number, recordedAt: now, uniquenessProven: evidence.uniquenessProven
        )
        // An unreadable file is only a cache of proofs; replace it rather than block the display.
        var records = (try? store.load()) ?? []
        records.removeAll {
            $0.route == record.route && $0.name == record.name && $0.candidates == record.candidates
                && $0.definitionDigest == record.definitionDigest
        }
        records.append(record)
        try store.save(Array(records.suffix(Self.maximumRecords)))
    }
}
