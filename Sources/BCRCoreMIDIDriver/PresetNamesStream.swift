import BCRSurfaceDomain
import Foundation

/// Name requests have 33 indexed replies and no cancel command. Keep the exchange
/// alive after cancellation until all replies arrive or the transport becomes idle.
struct PresetNamesStream {
    private var names: [Int: String] = [:]
    private(set) var failure: (any Error)?

    mutating func fail(_ error: any Error) { if failure == nil { failure = error } }

    mutating func receive(index: Int, name: String) -> Result<BCRPresetNames, any Error>? {
        names[index] = name
        guard let temporary = names[0x7F], (0 ... 31).allSatisfy({ names[$0] != nil }) else { return nil }
        if let failure { return .failure(failure) }
        return .success(BCRPresetNames(temporary: temporary, memory: (0 ... 31).map { names[$0]! }))
    }
}
