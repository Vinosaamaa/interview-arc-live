import Foundation

struct CodingProcessResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

typealias CodingControllerExecute = @Sendable (
    URL, [String], URL
) async throws -> CodingProcessResult

typealias CodingHarnessExecute = @Sendable (
    URL, [String], URL, [String: String]?
) async throws -> CodingProcessResult

struct CodingProcessStreamEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case stdout, stderr }
    var kind: Kind
    var text: String
}

enum CodingProcessRunnerError: Error, Equatable {
    case executableMissing(String)
    case launchFailed(String)
}

enum CodingProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]? = nil,
        onOutput: (@Sendable (CodingProcessStreamEvent) -> Void)? = nil
    ) async throws -> CodingProcessResult {
        let processBox = ProcessBox()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try launchAndWait(
                            executable: executable,
                            arguments: arguments,
                            currentDirectory: currentDirectory,
                            environment: environment,
                            onOutput: onOutput,
                            processBox: processBox
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            processBox.terminateIfRunning()
        }
        try Task.checkCancellation()
        return result
    }

    static func runBlocking(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) throws -> CodingProcessResult {
        try launchAndWait(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            onOutput: nil,
            processBox: ProcessBox()
        )
    }

    static func resolveNodeExecutable(
        fileManager: FileManager = .default
    ) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(
                fileURLWithPath: String(directory),
                isDirectory: true
            ).appendingPathComponent("node")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let fallbacks = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        return fallbacks
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func launchAndWait(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        onOutput: (@Sendable (CodingProcessStreamEvent) -> Void)?,
        processBox: ProcessBox
    ) throws -> CodingProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodingProcessRunnerError.executableMissing(executable.lastPathComponent)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            environment.forEach { merged[$0.key] = $0.value }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let buffer = OutputBuffer()
        if let onOutput {
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                emitAvailableData(
                    from: handle,
                    kind: .stdout,
                    buffer: buffer,
                    onOutput: onOutput
                )
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                emitAvailableData(
                    from: handle,
                    kind: .stderr,
                    buffer: buffer,
                    onOutput: onOutput
                )
            }
        }

        do {
            try process.run()
        } catch {
            throw CodingProcessRunnerError.launchFailed(error.localizedDescription)
        }
        processBox.attach(process)
        process.waitUntilExit()

        if let onOutput {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            emitAvailableData(
                from: stdoutPipe.fileHandleForReading,
                kind: .stdout,
                buffer: buffer,
                onOutput: onOutput
            )
            emitAvailableData(
                from: stderrPipe.fileHandleForReading,
                kind: .stderr,
                buffer: buffer,
                onOutput: onOutput
            )
            return buffer.result(exitCode: process.terminationStatus)
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return CodingProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func emitAvailableData(
        from handle: FileHandle,
        kind: CodingProcessStreamEvent.Kind,
        buffer: OutputBuffer,
        onOutput: @Sendable (CodingProcessStreamEvent) -> Void
    ) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }
        let event = CodingProcessStreamEvent(kind: kind, text: text)
        buffer.append(event)
        onOutput(event)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate {
            terminateIfNeeded(process)
        }
    }

    func terminateIfRunning() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process {
            terminateIfNeeded(process)
        }
    }

    private func terminateIfNeeded(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""

    func append(_ event: CodingProcessStreamEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event.kind {
        case .stdout:
            stdout += event.text
        case .stderr:
            stderr += event.text
        }
    }

    func result(exitCode: Int32) -> CodingProcessResult {
        lock.lock()
        defer { lock.unlock() }
        return CodingProcessResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }
}
