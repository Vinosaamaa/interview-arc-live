import Foundation
import XCTest

import InterviewArcLiveCore
@testable import InterviewArcLive

final class CodingHarnessClientTests: XCTestCase {
    func testMissingHarnessScriptReturnsNotReady() async throws {
        let fixture = try HarnessClientFixture(
            includeHarnessScript: false,
            includePublishedGeneration: false
        )
        defer { fixture.remove() }

        let receipt = await CodingHarnessClient.run(
            fixture.invocation(commandClass: .quickRun),
            identity: "run-missing"
        )

        XCTAssertEqual(receipt.outcome.label, "Local harness is not ready")
        XCTAssertFalse(receipt.outcome.label.localizedCaseInsensitiveContains("accepted"))
        if case .notReady(let reason) = receipt.outcome {
            XCTAssertTrue(
                reason.contains("leetcode-java-harness.mjs"),
                "reason was \(reason)"
            )
        } else {
            XCTFail("Expected a not-ready outcome")
        }
    }

    func testInjectedExecuteLocallyVerifiedNeverAccepted() async throws {
        let fixture = try HarnessClientFixture()
        defer { fixture.remove() }
        let recorder = ExecuteRecorder(
            result: CodingProcessResult(
                exitCode: 0,
                stdout: "Locally verified: Quick suite passed 2/2 tests.",
                stderr: ""
            )
        )
        let output = OutputRecorder()

        let receipt = await CodingHarnessClient.run(
            fixture.invocation(commandClass: .quickRun),
            identity: "run-verified",
            nodeExecutable: URL(fileURLWithPath: "/bin/sh"),
            execute: { executable, arguments, directory, environment in
                try await recorder.execute(
                    executable,
                    arguments,
                    directory,
                    environment
                )
            },
            onOutput: { text in
                output.append(text)
            }
        )

        XCTAssertEqual(receipt.outcome.label, "Locally verified")
        XCTAssertFalse(receipt.outcome.label.localizedCaseInsensitiveContains("accepted"))
        XCTAssertFalse(receipt.summaryLine.localizedCaseInsensitiveContains("accepted"))
        XCTAssertTrue(output.text().contains("Locally verified: Quick suite passed 2/2 tests."))
        if case .locallyVerified(let passed, let total) = receipt.outcome {
            XCTAssertEqual(passed, 2)
            XCTAssertEqual(total, 2)
        } else {
            XCTFail("Expected a locally verified outcome")
        }
    }

    func testInjectedExecuteReceivesRunFlagsAndFullOnlyForFullRun() async throws {
        let fixture = try HarnessClientFixture()
        defer { fixture.remove() }
        let recorder = ExecuteRecorder()
        let dummyNode = URL(fileURLWithPath: "/bin/sh")

        _ = await CodingHarnessClient.run(
            fixture.invocation(commandClass: .quickRun),
            identity: "run-quick",
            nodeExecutable: dummyNode,
            execute: { executable, arguments, directory, environment in
                try await recorder.execute(
                    executable,
                    arguments,
                    directory,
                    environment
                )
            }
        )
        _ = await CodingHarnessClient.run(
            fixture.invocation(commandClass: .fullRun),
            identity: "run-full",
            nodeExecutable: dummyNode,
            execute: { executable, arguments, directory, environment in
                try await recorder.execute(
                    executable,
                    arguments,
                    directory,
                    environment
                )
            }
        )

        let calls = recorder.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        assertHarnessArguments(
            calls[0].arguments,
            activityID: fixture.activityID,
            generationID: fixture.generationID,
            expectFull: false
        )
        assertHarnessArguments(
            calls[1].arguments,
            activityID: fixture.activityID,
            generationID: fixture.generationID,
            expectFull: true
        )
    }

    func testPublishedGenerationUsesHarnessStateRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "coding-harness-published-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let repositoryRoot = root.appendingPathComponent("repo", isDirectory: true)
        let scripts = repositoryRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scripts,
            withIntermediateDirectories: true
        )
        try Data("// fixture\n".utf8).write(
            to: scripts.appendingPathComponent("leetcode-java-harness.mjs")
        )

        let activityID = "activity-1"
        let harnessStateRoot = root.appendingPathComponent(
            "harness-state",
            isDirectory: true
        )
        let generationDir = harnessStateRoot
            .appendingPathComponent(activityID, isDirectory: true)
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent("gen-1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: generationDir,
            withIntermediateDirectories: true
        )
        try Data(#"{"generationId":"gen-1"}"#.utf8).write(
            to: harnessStateRoot
                .appendingPathComponent(activityID, isDirectory: true)
                .appendingPathComponent("active.json")
        )
        try Data(#"{"status":"ready"}"#.utf8).write(
            to: generationDir.appendingPathComponent("status.json")
        )

        let recorder = ExecuteRecorder(
            result: CodingProcessResult(
                exitCode: 0,
                stdout: "Locally verified: Quick suite passed 2/2 tests.",
                stderr: ""
            )
        )
        let receipt = await CodingHarnessClient.run(
            CodingHarnessInvocation(
                repositoryRoot: repositoryRoot,
                activityID: activityID,
                commandClass: .quickRun,
                harnessStateRoot: harnessStateRoot
            ),
            identity: "run-published",
            nodeExecutable: URL(fileURLWithPath: "/bin/sh"),
            execute: { executable, arguments, directory, environment in
                try await recorder.execute(
                    executable,
                    arguments,
                    directory,
                    environment
                )
            }
        )

        XCTAssertNotEqual(receipt.outcome.label, "Local harness is not ready")
        if case .locallyVerified = receipt.outcome {
            XCTAssertFalse(receipt.outcome.label.localizedCaseInsensitiveContains("accepted"))
        } else {
            XCTFail("Expected a locally verified outcome, got \(receipt.outcome)")
        }
        let calls = recorder.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        assertHarnessArguments(
            calls[0].arguments,
            activityID: activityID,
            generationID: "gen-1",
            expectFull: false
        )
    }
}

private func assertHarnessArguments(
    _ arguments: [String],
    activityID: String,
    generationID: String,
    expectFull: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(arguments.contains("run"), file: file, line: line)
    if let index = arguments.firstIndex(of: "--activity-id") {
        XCTAssertEqual(arguments[index + 1], activityID, file: file, line: line)
    } else {
        XCTFail("missing --activity-id", file: file, line: line)
    }
    if let index = arguments.firstIndex(of: "--generation-id") {
        XCTAssertEqual(arguments[index + 1], generationID, file: file, line: line)
    } else {
        XCTFail("missing --generation-id", file: file, line: line)
    }
    if expectFull {
        XCTAssertTrue(arguments.contains("--full"), file: file, line: line)
    } else {
        XCTAssertFalse(arguments.contains("--full"), file: file, line: line)
    }
}

private final class HarnessClientFixture {
    let root: URL
    let repositoryRoot: URL
    let harnessStateRoot: URL
    let activityID: String
    let generationID: String

    init(
        activityID: String = "activity-1",
        generationID: String = "gen-1",
        includeHarnessScript: Bool = true,
        includePublishedGeneration: Bool = true
    ) throws {
        self.activityID = activityID
        self.generationID = generationID
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "coding-harness-client-\(UUID().uuidString)",
            isDirectory: true
        )
        repositoryRoot = root.appendingPathComponent("repo", isDirectory: true)
        harnessStateRoot = root.appendingPathComponent(
            "harness-state",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: repositoryRoot,
            withIntermediateDirectories: true
        )
        if includeHarnessScript {
            let scripts = repositoryRoot.appendingPathComponent(
                "scripts",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: scripts,
                withIntermediateDirectories: true
            )
            try Data("// fixture\n".utf8).write(
                to: scripts.appendingPathComponent("leetcode-java-harness.mjs")
            )
        }
        if includePublishedGeneration {
            let generationDir = harnessStateRoot
                .appendingPathComponent(activityID, isDirectory: true)
                .appendingPathComponent("generations", isDirectory: true)
                .appendingPathComponent(generationID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: generationDir,
                withIntermediateDirectories: true
            )
            try Data("{\"generationId\":\"\(generationID)\"}".utf8).write(
                to: harnessStateRoot
                    .appendingPathComponent(activityID, isDirectory: true)
                    .appendingPathComponent("active.json")
            )
            try Data(#"{"status":"ready"}"#.utf8).write(
                to: generationDir.appendingPathComponent("status.json")
            )
        }
    }

    func invocation(commandClass: CodingHarnessCommandClass) -> CodingHarnessInvocation {
        CodingHarnessInvocation(
            repositoryRoot: repositoryRoot,
            activityID: activityID,
            commandClass: commandClass,
            harnessStateRoot: harnessStateRoot
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ExecuteRecorder: @unchecked Sendable {
    struct Call {
        var executable: URL
        var arguments: [String]
        var currentDirectory: URL
        var environment: [String: String]?
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private let result: CodingProcessResult

    init(result: CodingProcessResult = CodingProcessResult(exitCode: 0, stdout: "", stderr: "")) {
        self.result = result
    }

    func execute(
        _ executable: URL,
        _ arguments: [String],
        _ currentDirectory: URL,
        _ environment: [String: String]?
    ) async throws -> CodingProcessResult {
        lock.withLock {
            calls.append(
                Call(
                    executable: executable,
                    arguments: arguments,
                    currentDirectory: currentDirectory,
                    environment: environment
                )
            )
            return result
        }
    }

    func recordedCalls() -> [Call] {
        lock.withLock { calls }
    }
}

private final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []

    func append(_ text: String) {
        lock.withLock { chunks.append(text) }
    }

    func text() -> String {
        lock.withLock { chunks.joined() }
    }
}
