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
    private let maxBufferedLines: Int

    public init(maxBufferedLines: Int = 128) {
        self.maxBufferedLines = max(16, maxBufferedLines)
    }

    public func enqueueIncoming(_ line: String) async {
        guard !isClosed else {
            return
        }
        if waitingInput.isEmpty {
            inputQueue.append(line)
            if inputQueue.count > maxBufferedLines {
                inputQueue.removeFirst(inputQueue.count - maxBufferedLines)
            }
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

    public func consumeNextSentLine() -> String? {
        guard !output.isEmpty else {
            return nil
        }
        return output.removeFirst()
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

    public func clearInput() async {
        inputQueue.removeAll()
    }
}
