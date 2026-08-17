import Foundation

struct CodingProcessResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
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
        environment: [String: String]? = nil
    ) async throws -> CodingProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runBlocking(
                        executable: executable,
                        arguments: arguments,
                        currentDirectory: currentDirectory,
                        environment: environment
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runBlocking(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
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

        do {
            try process.run()
        } catch {
            throw CodingProcessRunnerError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()

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
}
