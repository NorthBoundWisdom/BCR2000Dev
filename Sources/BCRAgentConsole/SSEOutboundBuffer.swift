import Foundation

/// Bound deltas independently from full snapshots, including the packet currently being sent.
struct SSEOutboundBuffer: Sendable {
    enum Limit: Error { case snapshot, deltas }
    private struct Packet: Sendable { let data: Data; let snapshot: Bool }
    private var queue: [Packet] = []
    private var inFlight: Packet?
    private(set) var deltaBytes = 0
    private(set) var snapshotBytes = 0
    mutating func enqueue(_ data: Data, snapshot: Bool) throws {
        if snapshot {
            guard data.count <= 8 * 1024 * 1024 - snapshotBytes else { throw Limit.snapshot }
            snapshotBytes += data.count
        } else {
            guard data.count <= 65_536 - deltaBytes else { throw Limit.deltas }
            deltaBytes += data.count
        }
        queue.append(Packet(data: data, snapshot: snapshot))
    }

    mutating func next() -> Data? {
        guard inFlight == nil, !queue.isEmpty else { return nil }
        inFlight = queue.removeFirst()
        return inFlight?.data
    }

    mutating func complete() {
        guard let packet = inFlight else { return }
        if packet.snapshot { snapshotBytes -= packet.data.count } else { deltaBytes -= packet.data.count }
        inFlight = nil
    }
}
