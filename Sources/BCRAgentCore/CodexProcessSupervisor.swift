import Foundation
import Darwin

public enum CodexProcessSupervisorError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case executableNotFound(String)
    case launchFailed(String)
    case alreadyStopped

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            L10n.text("Codex 进程已在运行")
        case let .executableNotFound(path):
            L10n.text("未找到可执行文件：\(path)")
        case let .launchFailed(message):
            L10n.text("启动 Codex 失败：\(message)")
        case .alreadyStopped:
            L10n.text("Codex 进程未启动")
        }
    }
}

public enum CodexProcessExitReason: Equatable, Sendable {
    case exited(code: Int32)
    case crashed(code: Int32)
    case terminateRequested
    case launchFailed
    case interrupted
    case unknown
}

public struct CodexProcessExitEvent: Sendable {
    public let reason: CodexProcessExitReason
    public let pid: Int32?
    public let exitCode: Int32?
    public let timestamp: Date
    public let generation: Int
    public let restartCount: Int

    public init(
        reason: CodexProcessExitReason,
        pid: Int32? = nil,
        exitCode: Int32? = nil,
        timestamp: Date = .now,
        generation: Int,
        restartCount: Int
    ) {
        self.reason = reason
        self.pid = pid
        self.exitCode = exitCode
        self.timestamp = timestamp
        self.generation = generation
        self.restartCount = restartCount
    }
}

public struct CodexProcessSupervisorConfig: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let stopTimeoutMs: Int
    public let autoRestartLimit: Int
    public let autoRestartInitialDelayMs: Int
    public let autoRestartMaxDelayMs: Int

    public init(
        executablePath: String = "codex",
        arguments: [String] = ["app-server", "--listen", "stdio://", "--strict-config"],
        stopTimeoutMs: Int = 2_000,
        autoRestartLimit: Int = 0,
        autoRestartInitialDelayMs: Int = 250,
        autoRestartMaxDelayMs: Int = 3_000
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.stopTimeoutMs = stopTimeoutMs
        self.autoRestartLimit = autoRestartLimit
        self.autoRestartInitialDelayMs = autoRestartInitialDelayMs
        self.autoRestartMaxDelayMs = autoRestartMaxDelayMs
    }
}

public actor CodexProcessSupervisor {
    public typealias LogLineHandler = @Sendable (String) -> Void
    public typealias ExitHandler = @Sendable (CodexProcessExitEvent) -> Void

    public var onStdout: LogLineHandler?
    public var onStderr: LogLineHandler?
    public var onExit: ExitHandler?

    private var process: Process?
    private var standardInput: FileHandle?
    private var config: CodexProcessSupervisorConfig?

    private var isStopping = false
    private var isClosed = true
    private var currentGeneration = 0
    private var restartCount = 0

    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    private var stdoutLines: [String] = []
    private var protocolLines: [String] = []
    private var outputOverflow = false
    private var stdoutEOF = false
    private var stderrEOF = false
    private var stdoutWaiting: [CheckedContinuation<String?, Error>] = []
    private var stderrLines: [String] = []
    private var stderrWaiting: [CheckedContinuation<String?, Error>] = []
    private var stdoutLineLimit = 128
    private var stderrLineLimit = 128
    private var maxLineLength = 32_768

    public init(maxQueuedLines: Int = 128, maxLineLength: Int = 32_768) {
        self.stdoutLineLimit = max(1, maxQueuedLines)
        self.stderrLineLimit = max(1, maxQueuedLines)
        self.maxLineLength = max(1, maxLineLength)
    }

    public func setEventHandlers(
        onStdout: LogLineHandler? = nil,
        onStderr: LogLineHandler? = nil,
        onExit: ExitHandler? = nil
    ) {
        self.onStdout = onStdout
        self.onStderr = onStderr
        self.onExit = onExit
    }

    public func start(
        executablePath: String = "codex",
        arguments: [String] = ["app-server", "--listen", "stdio://", "--strict-config"],
        autoRestartLimit: Int = 0,
        autoRestartInitialDelayMs: Int = 250,
        autoRestartMaxDelayMs: Int = 3_000
    ) async throws {
        let config = CodexProcessSupervisorConfig(
            executablePath: executablePath,
            arguments: arguments,
            stopTimeoutMs: 2_000,
            autoRestartLimit: autoRestartLimit,
            autoRestartInitialDelayMs: autoRestartInitialDelayMs,
            autoRestartMaxDelayMs: autoRestartMaxDelayMs
        )
        try await start(config: config)
    }

    public func start(config: CodexProcessSupervisorConfig) async throws {
        guard !isRunning(), isClosed else {
            throw CodexProcessSupervisorError.alreadyRunning
        }

        self.config = config
        isStopping = false
        isClosed = false
        restartCount = 0
        currentGeneration += 1

        do {
            try await launch(for: currentGeneration)
        } catch {
            isClosed = true
            cleanup()
            throw error
        }
    }

    public func stop() async {
        guard !isClosed else {
            return
        }

        guard let config else {
            cleanup()
            return
        }

        isStopping = true
        isClosed = true

        await requestStop(withTimeoutMs: config.stopTimeoutMs)
        cleanup()
    }

    public func write(_ line: String) throws {
        guard process?.isRunning == true, let input = standardInput else {
            throw CodexProcessSupervisorError.alreadyStopped
        }

        guard let data = (line + "\n").data(using: .utf8) else {
            return
        }

        do {
            try input.write(contentsOf: data)
        } catch {
            throw CodexProcessSupervisorError.launchFailed(error.localizedDescription)
        }
    }

    public func isRunning() -> Bool {
        process?.isRunning == true
    }

    private func launch(for generation: Int) async throws {
        guard let config else {
            throw CodexProcessSupervisorError.launchFailed(L10n.text("配置未设置"))
        }

        guard let resolvedExecutable = Self.resolveExecutable(config.executablePath) else {
            throw CodexProcessSupervisorError.executableNotFound(config.executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedExecutable)
        process.arguments = config.arguments
        process.currentDirectoryURL = FileManager.default.currentDirectoryPath.isEmpty
            ? nil
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutReader = stdoutPipe.fileHandleForReading
        let stderrReader = stderrPipe.fileHandleForReading

        stdoutHandle = stdoutReader
        stderrHandle = stderrReader

        stdoutReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task {
                await self?.consumeDataChunk(data, isStdout: true, generation: generation)
            }
        }

        stderrReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task {
                await self?.consumeDataChunk(data, isStdout: false, generation: generation)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task {
                await self?.didTerminate(terminated, generation: generation)
            }
        }

        do {
            try process.run()
        } catch {
            cleanupPipes()
            throw CodexProcessSupervisorError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.standardInput = stdinPipe.fileHandleForWriting
        stdoutEOF = false
        stderrEOF = false
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)
        outputOverflow = false
        protocolLines.removeAll(keepingCapacity: true)
        stdoutLines.removeAll(keepingCapacity: true)
        stderrLines.removeAll(keepingCapacity: true)
        isClosed = false
    }

    private func requestStop(withTimeoutMs timeoutMs: Int) async {
        guard let process else {
            return
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))

        process.terminate()

        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        if process.isRunning {
            process.interrupt()
        }

        let emergencyDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while process.isRunning && ContinuousClock.now < emergencyDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            while process.isRunning {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func consumeDataChunk(_ data: Data, isStdout: Bool, generation: Int) {
        guard generation == currentGeneration else { return }
        if data.isEmpty {
            if isStdout { stdoutEOF = true } else { stderrEOF = true }
        }
        if isStdout { stdoutBuffer.append(data) } else { stderrBuffer.append(data) }
        processBuffer(isStdout: isStdout, atEOF: data.isEmpty)
    }

    private func processBuffer(isStdout: Bool, atEOF: Bool = false) {
        var buffer = isStdout ? stdoutBuffer : stderrBuffer
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            buffer.removeSubrange(...newline)
            if isStdout { emitStdout(line) } else { emitStderr(line) }
        }
        if atEOF, !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            if isStdout { emitStdout(line) } else { emitStderr(line) }
            buffer.removeAll()
        } else if buffer.count > maxLineLength {
            // Preserve the oversized line for the RPC decoder to reject, rather than silently
            // turning a partial JSON frame into a different valid message.
            let line = String(decoding: buffer, as: UTF8.self)
            if isStdout { emitStdout(line) } else { emitStderr(line) }
            buffer.removeAll()
        }
        if isStdout { stdoutBuffer = buffer } else { stderrBuffer = buffer }
    }

    private func flushStreamLine(isStdout: Bool) {
        processBuffer(isStdout: isStdout, atEOF: true)
    }

    private func emitStdout(_ line: String) {
        let safe = CodexLogSanitizer.sanitize(line)
        if !safe.isEmpty {
            onStdout?(safe)
        }

        guard !safe.isEmpty else {
            return
        }

        if let waiter = stdoutWaiting.first {
            stdoutWaiting.removeFirst()
            waiter.resume(returning: line)
            return
        }

        if protocolLines.count >= stdoutLineLimit {
            outputOverflow = true
            return
        }
        protocolLines.append(line)
        stdoutLines.append(safe)
        if stdoutLines.count > stdoutLineLimit {
            stdoutLines.removeFirst(stdoutLines.count - stdoutLineLimit)
        }
    }

    private func emitStderr(_ line: String) {
        let safe = CodexLogSanitizer.sanitize(line)
        if !safe.isEmpty {
            onStderr?(safe)
        }

        guard !safe.isEmpty else {
            return
        }

        stderrLines.append(safe)
        if stderrLines.count > stderrLineLimit {
            stderrLines.removeFirst(stderrLines.count - stderrLineLimit)
        }
    }

    private func didTerminate(_ process: Process, generation: Int) async {
        guard generation == currentGeneration else {
            return
        }

        // Process exit can arrive before the final pipe callbacks. Let those callbacks finish
        // before closing streams and failing pending RPC requests.
        let drainDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(stdoutEOF && stderrEOF), ContinuousClock.now < drainDeadline, generation == currentGeneration {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard generation == currentGeneration else { return }

        let exitCode = process.terminationStatus
        let reason: CodexProcessExitReason
        if isStopping {
            reason = .terminateRequested
        } else {
            switch process.terminationReason {
            case .exit:
                reason = exitCode == 0 ? .exited(code: exitCode) : .crashed(code: exitCode)
            case .uncaughtSignal:
                reason = .crashed(code: exitCode)
            @unknown default:
                reason = .unknown
            }
        }

        flushStreamLine(isStdout: true)
        flushStreamLine(isStdout: false)
        cleanup()

        let event = CodexProcessExitEvent(
            reason: reason,
            pid: process.processIdentifier,
            exitCode: exitCode,
            generation: generation,
            restartCount: restartCount
        )
        onExit?(event)

        await attemptRestartIfNeeded(reason: reason, generation: generation)
    }

    private func attemptRestartIfNeeded(reason: CodexProcessExitReason, generation: Int) async {
        guard !isStopping && !isClosed else {
            return
        }
        guard let config else {
            return
        }
        switch reason {
        case .exited(let code) where code == 0:
            isClosed = true
            return
        case .terminateRequested, .launchFailed:
            isClosed = true
            return
        case .exited, .crashed, .interrupted, .unknown:
            break
        }

        if restartCount >= config.autoRestartLimit {
            isClosed = true
            return
        }

        restartCount += 1
        var delayMs = max(0, min(config.autoRestartInitialDelayMs, config.autoRestartMaxDelayMs))
        for _ in 1 ..< restartCount {
            let cap = max(0, config.autoRestartMaxDelayMs)
            delayMs = delayMs >= cap / 2 ? cap : delayMs * 2
        }
        try? await Task.sleep(for: .milliseconds(delayMs))

        guard !isStopping && !isClosed, generation == currentGeneration else {
            return
        }

        let nextGeneration = generation + 1
        currentGeneration = nextGeneration
        do {
            try await launch(for: nextGeneration)
        } catch {
            onExit?(
                CodexProcessExitEvent(
                    reason: .launchFailed,
                    exitCode: nil,
                    generation: nextGeneration,
                    restartCount: restartCount
                )
            )
            isClosed = true
        }
    }

    private func cleanup() {
        if let stdoutHandle {
            stdoutHandle.readabilityHandler = nil
            self.stdoutHandle = nil
        }

        if let stderrHandle {
            stderrHandle.readabilityHandler = nil
            self.stderrHandle = nil
        }

        standardInput?.closeFile()
        while let waiter = stdoutWaiting.popLast() {
            waiter.resume(returning: nil)
        }
        while let waiter = stderrWaiting.popLast() {
            waiter.resume(returning: nil)
        }
        process?.terminate()
        process = nil
        standardInput = nil
    }

    private func cleanupPipes() {
        if let stdoutHandle {
            stdoutHandle.readabilityHandler = nil
            self.stdoutHandle = nil
        }

        if let stderrHandle {
            stderrHandle.readabilityHandler = nil
            self.stderrHandle = nil
        }
    }

    private static func resolveExecutable(_ path: String) -> String? {
        if path.contains("/") {
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }

        guard let pathList = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        for candidate in pathList.split(separator: ":") {
            let candidatePath = URL(fileURLWithPath: String(candidate)).appending(path: path).path
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }
        return nil
    }
}

extension CodexProcessSupervisor: CodexLineTransport {
    public func stdoutHistory() -> [String] {
        stdoutLines
    }

    public func stderrHistory() -> [String] {
        stderrLines
    }

    public func readLine() async throws -> String? {
        guard !outputOverflow else {
            throw CodexProcessSupervisorError.launchFailed(L10n.text("Codex 输出队列已满，连接必须重新启动"))
        }
        if let line = protocolLines.first {
            protocolLines.removeFirst()
            return line
        }

        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            stdoutWaiting.append(continuation)
        }
    }

    public func sendLine(_ line: String) async throws {
        try write(line)
    }

    public func close() async {
        await stop()
    }

    public func clearLineBufferForTest() {
        stdoutLines.removeAll(keepingCapacity: true)
        protocolLines.removeAll(keepingCapacity: true)
        stdoutWaiting.removeAll(keepingCapacity: true)
        stderrLines.removeAll(keepingCapacity: true)
        stderrWaiting.removeAll(keepingCapacity: true)
    }
}
