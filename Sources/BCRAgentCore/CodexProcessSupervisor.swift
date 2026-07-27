import Foundation

public enum CodexProcessSupervisorError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case executableNotFound(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Codex 进程已在运行"
        case let .executableNotFound(path):
            "未找到可执行文件：\(path)"
        case let .launchFailed(message):
            "启动 Codex 失败：\(message)"
        }
    }
}

public actor CodexProcessSupervisor {
    public typealias LogLineHandler = @Sendable (String) -> Void

    public var onStdout: LogLineHandler?
    public var onStderr: LogLineHandler?

    private var process: Process?
    private var standardInput: FileHandle?

    public init() {}

    public func start(
        executablePath: String = "codex",
        arguments: [String] = ["app-server", "--listen", "stdio://", "--strict-config"]
    ) async throws {
        guard process == nil || process?.isRunning != true else {
            throw CodexProcessSupervisorError.alreadyRunning
        }

        guard let resolvedExecutable = Self.resolveExecutable(executablePath) else {
            throw CodexProcessSupervisorError.executableNotFound(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedExecutable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.currentDirectoryPath.isEmpty
            ? nil
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let logQueue = DispatchQueue(label: "dev.bcragent.codex.log", qos: .utility)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            logQueue.async { [weak self] in
                Task { await self?.drain(handle: handle, isStdout: true) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            logQueue.async { [weak self] in
                Task { await self?.drain(handle: handle, isStdout: false) }
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task {
                await self?.didTerminate(terminated)
            }
        }

        do {
            try process.run()
            self.process = process
            self.standardInput = stdinPipe.fileHandleForWriting
        } catch {
            throw CodexProcessSupervisorError.launchFailed(error.localizedDescription)
        }
    }

    public func stop(timeout: Duration = .seconds(2)) async {
        guard let process, process.isRunning else {
            return
        }

        process.terminate()
        let end = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning && ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(40))
        }
        if process.isRunning {
            process.interrupt()
            while process.isRunning && ContinuousClock.now < end.advanced(by: .seconds(1)) {
                try? await Task.sleep(for: .milliseconds(40))
            }
            if process.isRunning {
                process.terminate()
            }
        }

        cleanup()
    }

    public func write(_ line: String) throws {
        guard let input = standardInput else {
            throw CodexProcessSupervisorError.launchFailed("stdin 未就绪")
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

    private func drain(
        handle: FileHandle,
        isStdout: Bool
    ) async {
        while let line = readLine(from: handle) {
            if isStdout {
                notifyStdout(line)
            } else {
                notifyStderr(line)
            }
        }
    }

    private func readLine(from handle: FileHandle) -> String? {
        let data = handle.availableData
        guard !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func didTerminate(_ process: Process) {
        cleanup()
    }

    private func cleanup() {
        process = nil
        standardInput = nil
    }

    private func notifyStdout(_ line: String) {
        onStdout?(line)
    }

    private func notifyStderr(_ line: String) {
        onStderr?(line)
    }

    private static func resolveExecutable(_ path: String) -> String? {
        if path.contains("/") {
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }

        guard let pathList = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        for candidate in pathList.split(separator: ":") {
            let candidatePath = URL(fileURLWithPath: String(candidate))
                .appending(path: path)
                .path
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }
        return nil
    }
}
