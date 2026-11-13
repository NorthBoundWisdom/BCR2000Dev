import BCRSurfaceDomain
import Foundation

/// Cancellation and malformed lines stop collection but cannot stop BCR transmission.
/// The caller retains its exclusive route until $end (or a transport idle timeout).
struct PresetDumpStream {
    private var frames: [[UInt8]] = []
    private(set) var failure: (any Error)?

    mutating func fail(_ error: any Error) {
        if failure == nil { failure = error }
        frames.removeAll()
    }

    /// Only complete BCR data frames are passed here by the SysEx decoder.
    mutating func receive(_ frame: [UInt8]) -> Result<Data, any Error>? {
        if failure == nil {
            if Int(frame[7]) * 128 + Int(frame[8]) != frames.count {
                fail(HardwareSnapshotError.invalid)
            } else {
                frames.append(frame)
            }
        }
        let text = String(decoding: frame[9 ..< frame.count - 1], as: UTF8.self)
        guard text.trimmingCharacters(in: .whitespaces) == "$end" else { return nil }
        if let failure { return .failure(failure) }
        return .success(Data(frames.joined()))
    }
}
