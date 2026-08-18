import Foundation
import InterviewArcLiveCore

struct CodingHarnessInvocation {
    var repositoryRoot: URL
    var activityID: String
    var commandClass: CodingHarnessCommandClass
    var harnessStateRoot: URL?
}

enum CodingHarnessClient {
    static func harnessScriptURL(repositoryRoot: URL) -> URL {
        repositoryRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("leetcode-java-harness.mjs")
    }

    static func isHarnessScriptPresent(
        repositoryRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(
            atPath: harnessScriptURL(repositoryRoot: repositoryRoot).path
        )
    }

    static func defaultHarnessStateRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["INTERVIEW_ARC_HARNESS_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("InterviewArc", isDirectory: true)
            .appendingPathComponent("leetcode-java-harnesses", isDirectory: true)
    }

    static func publishedGenerationID(
        activityID: String,
        harnessStateRoot: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let active = harnessStateRoot
            .appendingPathComponent(activityID, isDirectory: true)
            .appendingPathComponent("active.json")
        guard fileManager.fileExists(atPath: active.path),
              let data = try? Data(contentsOf: active),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let generationID = json["generationId"] as? String,
              !generationID.isEmpty else {
            return nil
        }
        let status = harnessStateRoot
            .appendingPathComponent(activityID, isDirectory: true)
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
            .appendingPathComponent("status.json")
        guard fileManager.fileExists(atPath: status.path),
              let statusData = try? Data(contentsOf: status),
              let statusJSON = try? JSONSerialization.jsonObject(with: statusData)
                as? [String: Any],
              statusJSON["status"] as? String == "ready" else {
            return nil
        }
        return generationID
    }

    static func run(
        _ invocation: CodingHarnessInvocation,
        identity: String = UUID().uuidString.lowercased(),
        fileManager: FileManager = .default,
        nodeExecutable: URL? = nil,
        execute: CodingHarnessExecute? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> CodingHarnessReceipt {
        let commandClass = invocation.commandClass
        guard isHarnessScriptPresent(
            repositoryRoot: invocation.repositoryRoot,
            fileManager: fileManager
        ) else {
            return .notReady(
                identity: identity,
                commandClass: commandClass,
                reason: "The linked Interview Arc checkout does not contain scripts/leetcode-java-harness.mjs."
            )
        }

        let stateRoot = invocation.harnessStateRoot ?? defaultHarnessStateRoot()
        guard let generationID = publishedGenerationID(
            activityID: invocation.activityID,
            harnessStateRoot: stateRoot,
            fileManager: fileManager
        ) else {
            return .notReady(identity: identity, commandClass: commandClass)
        }

        guard let node = nodeExecutable ?? CodingProcessRunner.resolveNodeExecutable(
            fileManager: fileManager
        ) else {
            return CodingHarnessReceipt.parse(
                identity: identity,
                commandClass: commandClass,
                exitCode: 127,
                stdout: "",
                stderr: "node is not available on this Mac."
            )
        }

        var arguments = [
            harnessScriptURL(repositoryRoot: invocation.repositoryRoot).path,
            "run",
            "--activity-id",
            invocation.activityID,
            "--generation-id",
            generationID,
        ]
        if commandClass == .fullRun {
            arguments.append("--full")
        }

        let environment: [String: String] = [
            "INTERVIEW_ARC_HARNESS_ROOT": stateRoot.path,
        ]

        do {
            let result: CodingProcessResult
            if let execute {
                result = try await execute(
                    node,
                    arguments,
                    invocation.repositoryRoot,
                    environment
                )
                forwardOutput(result, to: onOutput)
            } else {
                result = try await CodingProcessRunner.run(
                    executable: node,
                    arguments: arguments,
                    currentDirectory: invocation.repositoryRoot,
                    environment: environment,
                    onOutput: streamingCallback(forwarding: onOutput)
                )
            }
            return CodingHarnessReceipt.parse(
                identity: identity,
                commandClass: commandClass,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        } catch {
            return CodingHarnessReceipt.parse(
                identity: identity,
                commandClass: commandClass,
                exitCode: 1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }

    private static func streamingCallback(
        forwarding onOutput: (@Sendable (String) -> Void)?
    ) -> (@Sendable (CodingProcessStreamEvent) -> Void)? {
        guard let onOutput else { return nil }
        return { event in
            onOutput(event.text)
        }
    }

    private static func forwardOutput(
        _ result: CodingProcessResult,
        to onOutput: (@Sendable (String) -> Void)?
    ) {
        guard let onOutput else { return }
        if !result.stdout.isEmpty {
            onOutput(result.stdout)
        }
        if !result.stderr.isEmpty {
            onOutput(result.stderr)
        }
    }
}
