import Foundation
import InterviewArcLiveCore

struct LeetCodeControllerRequest: Equatable, Sendable {
    var repositoryRoot: URL
    var problemURL: URL
    var title: String
}

enum LeetCodeControllerClient {
    static let dedicatedProfileName = "leetcode-submitter"

    static func controllerScriptURL(repositoryRoot: URL) -> URL {
        repositoryRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("leetcode-playwright-controller.mjs")
    }

    static func openProblem(
        _ request: LeetCodeControllerRequest,
        fileManager: FileManager = .default,
        nodeExecutable: URL? = nil,
        execute: ((URL, [String], URL) async throws -> CodingProcessResult)? = nil
    ) async -> Result<String, Error> {
        let script = controllerScriptURL(repositoryRoot: request.repositoryRoot)
        guard fileManager.fileExists(atPath: script.path) else {
            return .failure(
                LeetCodeControllerError.controllerMissing
            )
        }
        guard let node = nodeExecutable ?? CodingProcessRunner.resolveNodeExecutable(
            fileManager: fileManager
        ) else {
            return .failure(LeetCodeControllerError.nodeMissing)
        }

        do {
            let ensure = try await run(
                node: node,
                arguments: [script.path, "ensure"],
                currentDirectory: request.repositoryRoot,
                execute: execute
            )
            if ensure.exitCode != 0 {
                return .failure(
                    LeetCodeControllerError.commandFailed(
                        command: "ensure",
                        diagnostics: diagnostics(ensure)
                    )
                )
            }

            let navigate = try await run(
                node: node,
                arguments: [
                    script.path,
                    "navigate",
                    request.problemURL.absoluteString,
                    "--title",
                    request.title,
                ],
                currentDirectory: request.repositoryRoot,
                execute: execute
            )
            if navigate.exitCode != 0 {
                return .failure(
                    LeetCodeControllerError.commandFailed(
                        command: "navigate",
                        diagnostics: diagnostics(navigate)
                    )
                )
            }
            return .success("Opened the verified LeetCode tab.")
        } catch {
            return .failure(error)
        }
    }

    static func makeInvocationID(prefix: String = "live-submit") -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }

    static func submit(
        _ request: LeetCodeControllerRequest,
        javaFile: URL,
        invocationID: String,
        command: CodingSubmissionCommand,
        fileManager: FileManager = .default,
        nodeExecutable: URL? = nil,
        execute: ((URL, [String], URL) async throws -> CodingProcessResult)? = nil
    ) async -> CodingSubmissionReceipt {
        guard command != .receipt else {
            assertionFailure("Receipt recovery must use recoverReceipt.")
            return failedReceipt(
                invocationID: invocationID,
                command: command,
                message: "Receipt recovery must use recoverReceipt."
            )
        }
        guard isValidInvocationID(invocationID) else {
            return failedReceipt(
                invocationID: invocationID,
                command: command,
                message: "The controller invocation ID is not valid."
            )
        }
        switch resolveController(
            repositoryRoot: request.repositoryRoot,
            invocationID: invocationID,
            command: command,
            fileManager: fileManager,
            nodeExecutable: nodeExecutable
        ) {
        case .failed(let receipt):
            return receipt
        case .ready(let script, let node):
            let arguments = [
                script.path,
                command.rawValue,
                request.problemURL.absoluteString,
                javaFile.path,
                "--title",
                request.title,
                "--invocation-id",
                invocationID,
            ]
            return await invoke(
                node: node,
                arguments: arguments,
                currentDirectory: request.repositoryRoot,
                invocationID: invocationID,
                command: command,
                execute: execute
            )
        }
    }

    static func recoverReceipt(
        repositoryRoot: URL,
        invocationID: String,
        fileManager: FileManager = .default,
        nodeExecutable: URL? = nil,
        execute: ((URL, [String], URL) async throws -> CodingProcessResult)? = nil
    ) async -> CodingSubmissionReceipt {
        let command = CodingSubmissionCommand.receipt
        guard isValidInvocationID(invocationID) else {
            return failedReceipt(
                invocationID: invocationID,
                command: command,
                message: "The controller invocation ID is not valid."
            )
        }
        switch resolveController(
            repositoryRoot: repositoryRoot,
            invocationID: invocationID,
            command: command,
            fileManager: fileManager,
            nodeExecutable: nodeExecutable
        ) {
        case .failed(let receipt):
            return receipt
        case .ready(let script, let node):
            let arguments = [
                script.path,
                "receipt",
                "--invocation-id",
                invocationID,
            ]
            return await invoke(
                node: node,
                arguments: arguments,
                currentDirectory: repositoryRoot,
                invocationID: invocationID,
                command: command,
                execute: execute
            )
        }
    }

    static func submitRecoveringAmbiguousOutput(
        _ request: LeetCodeControllerRequest,
        javaFile: URL,
        invocationID: String,
        command: CodingSubmissionCommand,
        fileManager: FileManager = .default,
        nodeExecutable: URL? = nil,
        execute: ((URL, [String], URL) async throws -> CodingProcessResult)? = nil
    ) async -> CodingSubmissionReceipt {
        let receipt = await submit(
            request,
            javaFile: javaFile,
            invocationID: invocationID,
            command: command,
            fileManager: fileManager,
            nodeExecutable: nodeExecutable,
            execute: execute
        )
        guard case .ambiguous = receipt.outcome else {
            return receipt
        }
        return await recoverReceipt(
            repositoryRoot: request.repositoryRoot,
            invocationID: invocationID,
            fileManager: fileManager,
            nodeExecutable: nodeExecutable,
            execute: execute
        )
    }

    private enum ControllerResolution {
        case ready(script: URL, node: URL)
        case failed(CodingSubmissionReceipt)
    }

    private static func resolveController(
        repositoryRoot: URL,
        invocationID: String,
        command: CodingSubmissionCommand,
        fileManager: FileManager,
        nodeExecutable: URL?
    ) -> ControllerResolution {
        let script = controllerScriptURL(repositoryRoot: repositoryRoot)
        guard fileManager.fileExists(atPath: script.path) else {
            return .failed(
                failedReceipt(
                    invocationID: invocationID,
                    command: command,
                    message: LeetCodeControllerError.controllerMissing.errorDescription
                        ?? "Open LeetCode needs a linked Interview Arc checkout with the checked-in Playwright controller."
                )
            )
        }
        guard let node = nodeExecutable ?? CodingProcessRunner.resolveNodeExecutable(
            fileManager: fileManager
        ) else {
            return .failed(
                failedReceipt(
                    invocationID: invocationID,
                    command: command,
                    message: LeetCodeControllerError.nodeMissing.errorDescription
                        ?? "node is not available on this Mac."
                )
            )
        }
        return .ready(script: script, node: node)
    }

    private static func invoke(
        node: URL,
        arguments: [String],
        currentDirectory: URL,
        invocationID: String,
        command: CodingSubmissionCommand,
        execute: ((URL, [String], URL) async throws -> CodingProcessResult)?
    ) async -> CodingSubmissionReceipt {
        do {
            let result = try await run(
                node: node,
                arguments: arguments,
                currentDirectory: currentDirectory,
                execute: execute
            )
            return CodingSubmissionReceipt.parse(
                invocationID: invocationID,
                command: command,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        } catch {
            return failedReceipt(
                invocationID: invocationID,
                command: command,
                message: error.localizedDescription
            )
        }
    }

    private static func failedReceipt(
        invocationID: String,
        command: CodingSubmissionCommand,
        message: String
    ) -> CodingSubmissionReceipt {
        CodingSubmissionReceipt(
            invocationID: invocationID,
            command: command,
            outcome: .failed(code: nil, message: message),
            diagnostics: message
        )
    }

    private static func isValidInvocationID(_ invocationID: String) -> Bool {
        invocationID.wholeMatch(of: /^[a-z0-9][a-z0-9._-]{0,127}$/) != nil
    }

    private static func run(
        node: URL,
        arguments: [String],
        currentDirectory: URL,
        execute: ((URL, [String], URL) async throws -> CodingProcessResult)?
    ) async throws -> CodingProcessResult {
        if let execute {
            return try await execute(node, arguments, currentDirectory)
        }
        return try await CodingProcessRunner.run(
            executable: node,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
    }

    private static func diagnostics(_ result: CodingProcessResult) -> String {
        let combined = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return combined.isEmpty
            ? "exit \(result.exitCode)"
            : combined
    }
}

enum LeetCodeControllerError: Error, Equatable, LocalizedError {
    case controllerMissing
    case nodeMissing
    case commandFailed(command: String, diagnostics: String)
    case missingProblemURL

    var errorDescription: String? {
        switch self {
        case .controllerMissing:
            "Open LeetCode needs a linked Interview Arc checkout with the checked-in Playwright controller."
        case .nodeMissing:
            "node is not available on this Mac."
        case .commandFailed(let command, let diagnostics):
            "The LeetCode controller \(command) command did not succeed. \(diagnostics)"
        case .missingProblemURL:
            "This activity does not have a verified LeetCode URL."
        }
    }
}
