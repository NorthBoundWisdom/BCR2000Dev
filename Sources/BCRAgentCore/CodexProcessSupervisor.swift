import Foundation

public enum CodexProcessSupervisorError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case executableNotFound(String)
    case launchFailed(String)
    case alreadyStopped

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Codex 进程已在运行"
        case let .executableNotFound(path):
            "未找到可执行文件：\(path)"
        case let .launchFailed(message):
            "启动 Codex 失败：\(message)"
        case .alreadyStopped:
            "Codex 进程未启动"
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
    private var isClosed = false
    private var currentGeneration = 0
    private var restartCount = 0

    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    private var stdoutLines: [String] = []
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
        guard !isRunning() else {
            throw CodexProcessSupervisorError.alreadyRunning
        }

        self.config = config
        isStopping = false
        isClosed = false
        restartCount = 0
        currentGeneration += 1

        try await launch(for: currentGeneration)
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
        guard let input = standardInput else {
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
            throw CodexProcessSupervisorError.launchFailed("配置未设置")
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
            Task {
                await self?.consumeDataChunk(data, isStdout: true)
            }
        }

        stderrReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                await self?.consumeDataChunk(data, isStdout: false)
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
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)
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
            process.terminate()
        }
    }

    private func consumeDataChunk(_ data: Data, isStdout: Bool) async {
        if isStdout {
            guard !data.isEmpty else {
                flushStreamLine(isStdout: true)
                return
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            stdoutBuffer.append(text)
            processBuffer(isStdout: true)
            return
        }

        guard !data.isEmpty else {
            flushStreamLine(isStdout: false)
            return
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        stderrBuffer.append(text)
        processBuffer(isStdout: false)
    }

    private func processBuffer(isStdout: Bool) {
        if isStdout {
            while let newlineIndex = stdoutBuffer.firstIndex(of: "\n") {
                let line = String(stdoutBuffer[..<newlineIndex])
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
                emitStdout(line.trimmingCharacters(in: .newlines))
            }
            if stdoutBuffer.count > maxLineLength {
                let truncated = String(stdoutBuffer.prefix(maxLineLength))
                stdoutBuffer.removeFirst(truncated.count)
                emitStdout(truncated)
            }
            return
        }

        while let newlineIndex = stderrBuffer.firstIndex(of: "\n") {
            let line = String(stderrBuffer[..<newlineIndex])
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...newlineIndex)
            emitStderr(line.trimmingCharacters(in: .newlines))
        }
        if stderrBuffer.count > maxLineLength {
            let truncated = String(stderrBuffer.prefix(maxLineLength))
            stderrBuffer.removeFirst(truncated.count)
            emitStderr(truncated)
        }
    }

    private func flushStreamLine(isStdout: Bool) {
        if isStdout {
            if !stdoutBuffer.isEmpty {
                emitStdout(stdoutBuffer.trimmingCharacters(in: .newlines))
                stdoutBuffer.removeAll(keepingCapacity: true)
            }
        } else if !stderrBuffer.isEmpty {
            emitStderr(stderrBuffer.trimmingCharacters(in: .newlines))
            stderrBuffer.removeAll(keepingCapacity: true)
        }
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
            waiter.resume(returning: safe)
            return
        }

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
        let delayMs = min(
            config.autoRestartMaxDelayMs,
            config.autoRestartInitialDelayMs * (1 << (restartCount - 1))
        )
        try? await Task.sleep(for: .milliseconds(delayMs))

        guard !isStopping && !isClosed else {
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
        if isClosed {
            return nil
        }

        if let line = stdoutLines.first {
            stdoutLines.removeFirst()
            return line
        }

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
        stdoutWaiting.removeAll(keepingCapacity: true)
        stderrLines.removeAll(keepingCapacity: true)
        stderrWaiting.removeAll(keepingCapacity: true)
    }
}
