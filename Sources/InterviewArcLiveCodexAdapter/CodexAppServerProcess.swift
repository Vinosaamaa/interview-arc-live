import Foundation
import Darwin

enum CodexProcessFailure: Error, Sendable, Equatable {
    case launch
    case io
    case outputLimit
    case timedOut
}

struct CodexCommandResult: Sendable, Equatable {
    let standardOutput: Data
    let exitCode: Int32
}

protocol CodexAppServerProcessConnection: Sendable {
    func send(_ data: Data) async throws
    func receiveLine() async throws -> Data?
    func waitForExit() async -> Int32
    func terminate() async
}

protocol CodexAppServerProcessLaunching: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeoutNanoseconds: UInt64,
        outputLimit: Int
    ) async throws -> CodexCommandResult

    func connect(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        lineLimit: Int,
        totalOutputLimit: Int
    ) async throws -> any CodexAppServerProcessConnection
}

struct FoundationCodexAppServerProcessLauncher: CodexAppServerProcessLaunching {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeoutNanoseconds: UInt64,
        outputLimit: Int
    ) async throws -> CodexCommandResult {
        let connection = try await connect(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            lineLimit: outputLimit,
            totalOutputLimit: outputLimit
        )

        do {
            let result = try await withThrowingTaskGroup(of: CodexCommandResult.self) { group in
                group.addTask {
                    var output = Data()
                    while let line = try await connection.receiveLine() {
                        if !output.isEmpty {
                            output.append(0x0A)
                        }
                        output.append(line)
                        guard output.count <= outputLimit else {
                            throw CodexProcessFailure.outputLimit
                        }
                    }
                    return CodexCommandResult(
                        standardOutput: output,
                        exitCode: await connection.waitForExit()
                    )
                }
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        // Parent cancellation must also unblock the reader before
                        // structured concurrency waits for this group to drain.
                        await connection.terminate()
                        throw error
                    }
                    await connection.terminate()
                    throw CodexProcessFailure.timedOut
                }

                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw CodexProcessFailure.io
                }
                return first
            }
            // Close inherited pipe handles even after a normal child exit and ensure
            // Process has been reaped before returning to the caller.
            try Task.checkCancellation()
            await connection.terminate()
            return result
        } catch {
            // Output-limit and reader I/O failures can happen while the child is still
            // running. No run path may abandon that process.
            await connection.terminate()
            throw error
        }
    }

    func connect(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        lineLimit: Int,
        totalOutputLimit: Int
    ) async throws -> any CodexAppServerProcessConnection {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // Provider stderr can contain account or filesystem details. The Adapter never
        // retains it; a zero-byte buffer is the strictest possible memory bound.
        process.standardError = FileHandle.nullDevice

        // `waitUntilExit()` polls the current thread's run loop, which is not a
        // safe assumption on Swift concurrency's detached worker threads. Install
        // the completion observer before launch so even an immediate exit is
        // retained for every current or future waiter.
        let exitWaiter = ProcessExitWaiter()
        process.terminationHandler = { [exitWaiter] process in
            exitWaiter.finish(with: process.terminationStatus)
        }

        // A concurrent cancellation closes stdin while a detached writer may be
        // blocked. Convert the resulting broken pipe into a Swift error instead of
        // allowing SIGPIPE to terminate the Live app process.
        guard Darwin.fcntl(
            input.fileHandleForWriting.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        ) == 0 else {
            throw CodexProcessFailure.io
        }

        do {
            try process.run()
        } catch {
            throw CodexProcessFailure.launch
        }

        return FoundationCodexAppServerConnection(
            process: process,
            inputPipe: input,
            outputPipe: output,
            lineLimit: lineLimit,
            totalOutputLimit: totalOutputLimit,
            exitWaiter: exitWaiter
        )
    }
}

private final class SendableProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitCode {
                lock.unlock()
                continuation.resume(returning: exitCode)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(with exitCode: Int32) {
        lock.lock()
        guard self.exitCode == nil else {
            lock.unlock()
            return
        }
        self.exitCode = exitCode
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for waiter in waiters {
            waiter.resume(returning: exitCode)
        }
    }
}

private final class BlockingLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lineLimit: Int
    private let totalOutputLimit: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var totalBytes = 0
    private var reachedEnd = false

    init(handle: FileHandle, lineLimit: Int, totalOutputLimit: Int) {
        self.handle = handle
        self.lineLimit = lineLimit
        self.totalOutputLimit = totalOutputLimit
    }

    func nextLine() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }

        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard line.count <= lineLimit else {
                    throw CodexProcessFailure.outputLimit
                }
                if line.last == 0x0D {
                    return Data(line.dropLast())
                }
                return line
            }

            if reachedEnd {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer.removeAll(keepingCapacity: false)
                guard line.count <= lineLimit else {
                    throw CodexProcessFailure.outputLimit
                }
                if line.last == 0x0D {
                    return Data(line.dropLast())
                }
                return line
            }

            // `read(upToCount:)` waits for the full requested count on Darwin
            // pipes, which deadlocks a long-lived JSONL server after a short line.
            // `availableData` waits for at least one byte and then returns the
            // currently available bounded chunk.
            let chunk = handle.availableData
            if chunk.isEmpty {
                reachedEnd = true
                continue
            }
            totalBytes += chunk.count
            guard totalBytes <= totalOutputLimit else {
                throw CodexProcessFailure.outputLimit
            }
            buffer.append(chunk)
            guard buffer.count <= lineLimit else {
                throw CodexProcessFailure.outputLimit
            }
        }
    }

    func close() {
        // Closing the read side unblocks a pending blocking read even if an
        // unexpected descendant inherited the provider's stdout descriptor.
        try? handle.close()
    }
}

private final class BlockingWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    func close() {
        // Deliberately do not take `lock`: closing the independently retained
        // descriptor (and killing the child) must unblock a wedged pipe write.
        try? handle.close()
    }
}

private actor FoundationCodexAppServerConnection: CodexAppServerProcessConnection {
    private static let terminationGraceNanoseconds: UInt64 = 500_000_000
    private static let terminationPollNanoseconds: UInt64 = 20_000_000

    private let processBox: SendableProcessBox
    // Retain both Pipe owners. Retaining only their FileHandles lets Pipe deinit
    // close a descriptor after connect(), breaking the second JSONL write.
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private let writer: BlockingWriter
    private let reader: BlockingLineReader
    private let exitWaiter: ProcessExitWaiter
    private var didTerminate = false
    private var terminationCompleted = false
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        process: Process,
        inputPipe: Pipe,
        outputPipe: Pipe,
        lineLimit: Int,
        totalOutputLimit: Int,
        exitWaiter: ProcessExitWaiter
    ) {
        processBox = SendableProcessBox(process)
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        writer = BlockingWriter(handle: inputPipe.fileHandleForWriting)
        reader = BlockingLineReader(
            handle: outputPipe.fileHandleForReading,
            lineLimit: lineLimit,
            totalOutputLimit: totalOutputLimit
        )
        self.exitWaiter = exitWaiter
    }

    func send(_ data: Data) async throws {
        guard !didTerminate else { throw CodexProcessFailure.io }
        do {
            try await Task.detached(priority: .userInitiated) { [writer] in
                try writer.write(data)
            }.value
        } catch {
            throw CodexProcessFailure.io
        }
    }

    func receiveLine() async throws -> Data? {
        try await Task.detached(priority: .userInitiated) { [reader] in
            try reader.nextLine()
        }.value
    }

    func waitForExit() async -> Int32 {
        await exitWaiter.wait()
    }

    func terminate() async {
        if didTerminate {
            guard !terminationCompleted else { return }
            await withCheckedContinuation { continuation in
                terminationWaiters.append(continuation)
            }
            return
        }
        didTerminate = true
        writer.close()
        reader.close()
        guard processBox.process.isRunning else {
            _ = await waitForExit()
            finishTermination()
            return
        }

        let processIdentifier = processBox.process.processIdentifier
        _ = Darwin.kill(processIdentifier, SIGTERM)
        if !(await waitForExit(
            withinNanoseconds: Self.terminationGraceNanoseconds
        )) {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        // SIGKILL is not catchable. Waiting here both closes the stdout pipe for any
        // blocked reader and reaps the child, preventing a zombie.
        _ = await waitForExit()
        finishTermination()
    }

    private func waitForExit(withinNanoseconds limit: UInt64) async -> Bool {
        var remaining = limit
        while processBox.process.isRunning, remaining > 0 {
            let interval = min(Self.terminationPollNanoseconds, remaining)
            try? await Task.sleep(nanoseconds: interval)
            remaining -= interval
        }
        return !processBox.process.isRunning
    }

    private func finishTermination() {
        terminationCompleted = true
        let waiters = terminationWaiters
        terminationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
