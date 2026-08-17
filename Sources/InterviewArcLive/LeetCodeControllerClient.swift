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
