import Foundation

public protocol CodexLineTransport: Sendable {
    func readLine() async throws -> String?
    func sendLine(_ line: String) async throws
    func close() async
}

/// A pure in-memory transport for unit tests and fixture replay.
public actor InMemoryJSONLTransport: CodexLineTransport {
    public enum TransportError: Error {
        case closed
    }

    private var inputQueue: [String] = []
    private var waitingInput: [CheckedContinuation<String?, Error>] = []
    private var output: [String] = []
    private var isClosed = false

    public init() {}

    public func enqueueIncoming(_ line: String) async {
        if waitingInput.isEmpty {
            inputQueue.append(line)
            return
        }

        let continuation = waitingInput.removeFirst()
        continuation.resume(returning: line)
    }

    public func readLine() async throws -> String? {
        if isClosed {
            return nil
        }
        if let line = inputQueue.first {
            inputQueue.removeFirst()
            return line
        }

        return try await withCheckedThrowingContinuation { continuation in
            waitingInput.append(continuation)
        }
    }

    public func sendLine(_ line: String) async throws {
        guard !isClosed else {
            throw TransportError.closed
        }
        output.append(line)
    }

    public func consumeSentLines() async -> [String] {
        let snapshot = output
        output.removeAll()
        return snapshot
    }

    public func close() async {
        isClosed = true

        for waiter in waitingInput {
            waiter.resume(returning: nil)
        }
        waitingInput.removeAll()
        inputQueue.removeAll()
    }

    public func clear() async {
        output.removeAll()
    }
}
