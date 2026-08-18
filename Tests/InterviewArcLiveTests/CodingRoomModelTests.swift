import Foundation
import XCTest

import InterviewArcLiveCore
import InterviewArcLiveHostedClient
@testable import InterviewArcLive

@MainActor
final class CodingRoomModelTests: XCTestCase {
    func testCodingGateWhenBoundSpecialtyIsLeetCodeAndActivityIsNil() {
        let model = CodingRoomModel(
            initialHostedSnapshot: HostedPracticeSnapshot(
                connection: .noOpenSystemDesignActivity,
                boundSpecialty: .leetcode
            )
        )

        XCTAssertTrue(model.isCodingActivityMissing)
        XCTAssertFalse(model.canToggleHostedTimer)
        XCTAssertFalse(model.canSetHostedResult)
        XCTAssertFalse(model.isJavaFileLoaded)
        XCTAssertEqual(model.actionTitle, "Hand off")
        XCTAssertEqual(model.hostedConnectionTitle, "No coding activity")
        XCTAssertEqual(model.question, "Open a LeetCode activity on Today")
        XCTAssertEqual(
            model.floorStatePresentation.full.label,
            "Open a LeetCode activity"
        )
    }

    func testLocalSuccessLabelIsNeverAccepted() {
        let receipt = CodingHarnessReceipt.parse(
            identity: "run-gate",
            commandClass: .quickRun,
            exitCode: 0,
            stdout: "Locally verified: Quick suite passed 3/3 tests. This is not a LeetCode Accepted verdict.\n",
            stderr: ""
        )
        XCTAssertEqual(receipt.outcome.label, "Locally verified")
        XCTAssertFalse(receipt.outcome.label.localizedCaseInsensitiveContains("accepted"))
    }

    func testQuickRunPaintsRunningWithoutSettingIsWorking() async throws {
        let env = try CodingRoomTestFixture.make()
        defer { env.remove() }
        let gate = RunGate()
        let model = CodingRoomModel(
            applicationSupportRoot: env.supportRoot,
            initialHostedSnapshot: env.snapshot,
            harnessExecute: { _, _, _, _ in
                try await gate.wait()
            }
        )
        model.bindLoadedJavaFileForTesting(fileURL: env.javaFile, text: env.source)

        let run = Task { await model.quickRun() }
        try await waitUntil {
            model.isHarnessRunning && model.latestRunReceipt?.outcome == .running
        }
        XCTAssertTrue(model.isHarnessRunning)
        XCTAssertEqual(model.latestRunReceipt?.outcome, .running)
        XCTAssertFalse(model.isWorking)

        await gate.resume(
            CodingProcessResult(
                exitCode: 0,
                stdout: "Locally verified: Quick suite passed 3/3 tests. This is not a LeetCode Accepted verdict.\n",
                stderr: ""
            )
        )
        await run.value

        XCTAssertEqual(model.latestRunReceipt?.outcome.label, "Locally verified")
        XCTAssertFalse(
            model.latestRunReceipt?.outcome.label.localizedCaseInsensitiveContains("accepted")
                ?? false
        )
        XCTAssertFalse(model.isHarnessRunning)
        XCTAssertFalse(model.isWorking)
    }

    func testLatestQuickRunCancelsPrevious() async throws {
        let env = try CodingRoomTestFixture.make()
        defer { env.remove() }
        let blocker = FirstRunBlocker()
        let model = CodingRoomModel(
            applicationSupportRoot: env.supportRoot,
            initialHostedSnapshot: env.snapshot,
            harnessExecute: { _, _, _, _ in
                try await blocker.nextResult()
            }
        )
        model.bindLoadedJavaFileForTesting(fileURL: env.javaFile, text: env.source)

        let first = Task { await model.quickRun() }
        await blocker.waitUntilStarted()
        let second = Task { await model.quickRun() }
        await first.value
        await second.value

        XCTAssertEqual(model.latestRunReceipt?.outcome.label, "Locally verified")
        XCTAssertEqual(
            model.latestRunReceipt?.diagnostics.contains("passed 1/1"),
            true
        )
        XCTAssertFalse(
            model.latestRunReceipt?.diagnostics.contains("superseded-first-run")
                ?? false
        )
        XCTAssertFalse(model.isHarnessRunning)
        XCTAssertFalse(model.isWorking)
    }

    func testSubmitDoesNotSetIsWorkingAndUsesUniqueInvocationId() async throws {
        let env = try CodingRoomTestFixture.make()
        defer { env.remove() }
        let log = ArgumentLog()
        let model = CodingRoomModel(
            applicationSupportRoot: env.supportRoot,
            initialHostedSnapshot: env.snapshot,
            controllerExecute: { _, arguments, _ in
                log.append(arguments)
                return CodingProcessResult(
                    exitCode: 0,
                    stdout: #"{"ok":true,"result":{"verdict":"Accepted"}}"#,
                    stderr: ""
                )
            }
        )
        model.bindLoadedJavaFileForTesting(fileURL: env.javaFile, text: env.source)

        await model.submitToLeetCode()

        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertEqual(model.latestSubmissionReceipt?.outcome, .accepted)
        XCTAssertTrue(model.latestSubmissionReceipt?.outcome.isAccepted == true)
        let firstArguments = try XCTUnwrap(log.snapshot.first)
        XCTAssertTrue(firstArguments.contains("submit"))
        XCTAssertTrue(firstArguments.contains("--invocation-id"))
        let firstID = try XCTUnwrap(invocationID(in: firstArguments))

        await model.submitToLeetCode()

        XCTAssertFalse(model.isWorking)
        let recorded = log.snapshot
        XCTAssertEqual(recorded.count, 2)
        let secondArguments = recorded[1]
        XCTAssertTrue(secondArguments.contains("retry"))
        XCTAssertFalse(secondArguments.contains("submit"))
        let secondID = try XCTUnwrap(invocationID(in: secondArguments))
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(model.latestSubmissionReceipt?.outcome, .accepted)
    }

    func testAmbiguousSubmitRecoversReceiptOnceWithSameId() async throws {
        let env = try CodingRoomTestFixture.make()
        defer { env.remove() }
        let log = ArgumentLog()
        let model = CodingRoomModel(
            applicationSupportRoot: env.supportRoot,
            initialHostedSnapshot: env.snapshot,
            controllerExecute: { _, arguments, _ in
                log.append(arguments)
                if arguments.contains("receipt") {
                    return CodingProcessResult(
                        exitCode: 0,
                        stdout: #"{"ok":true,"result":{"verdict":"Wrong Answer"}}"#,
                        stderr: ""
                    )
                }
                return CodingProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        model.bindLoadedJavaFileForTesting(fileURL: env.javaFile, text: env.source)

        await model.submitToLeetCode()

        let recorded = log.snapshot
        XCTAssertEqual(recorded.filter { $0.contains("submit") }.count, 1)
        XCTAssertEqual(recorded.filter { $0.contains("receipt") }.count, 1)
        let submitID = try XCTUnwrap(
            recorded.first { $0.contains("submit") }.flatMap(invocationID(in:))
        )
        let receiptID = try XCTUnwrap(
            recorded.first { $0.contains("receipt") }.flatMap(invocationID(in:))
        )
        XCTAssertEqual(submitID, receiptID)
        XCTAssertFalse(model.latestSubmissionReceipt?.outcome.isAccepted ?? true)
        XCTAssertFalse(model.isWorking)
        guard case .rejected(let verdict) = model.latestSubmissionReceipt?.outcome else {
            return XCTFail("Expected a rejected controller verdict")
        }
        XCTAssertEqual(verdict, "Wrong Answer")
    }
}

private struct CodingRoomTestFixture {
    var root: URL
    var supportRoot: URL
    var javaFile: URL
    var source: String
    var snapshot: HostedPracticeSnapshot

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func make() throws -> CodingRoomTestFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "live-coding-room-\(UUID().uuidString)",
            isDirectory: true
        )
        let supportRoot = root.appendingPathComponent("support", isDirectory: true)
        let repoRoot = root.appendingPathComponent("repo", isDirectory: true)
        let scripts = repoRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scripts,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: supportRoot,
            withIntermediateDirectories: true
        )
        try Data("// controller\n".utf8).write(
            to: scripts.appendingPathComponent("leetcode-playwright-controller.mjs")
        )
        try Data("// harness\n".utf8).write(
            to: scripts.appendingPathComponent("leetcode-java-harness.mjs")
        )

        let link = CodingWorkspaceLink(interviewArcRepositoryRoot: repoRoot.path)
        try JSONEncoder().encode(link).write(
            to: supportRoot.appendingPathComponent("WorkspaceLink.json")
        )

        let harnessRoot = supportRoot
            .appendingPathComponent("leetcode-java-harnesses", isDirectory: true)
            .appendingPathComponent("activity-code", isDirectory: true)
        let generation = harnessRoot
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent("gen-1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: generation,
            withIntermediateDirectories: true
        )
        try Data(#"{"generationId":"gen-1"}"#.utf8).write(
            to: harnessRoot.appendingPathComponent("active.json")
        )
        try Data(#"{"status":"ready"}"#.utf8).write(
            to: generation.appendingPathComponent("status.json")
        )

        let javaFile = root.appendingPathComponent("solution.java")
        let source = "class Solution {}\n"
        try Data(source.utf8).write(to: javaFile)

        return CodingRoomTestFixture(
            root: root,
            supportRoot: supportRoot,
            javaFile: javaFile,
            source: source,
            snapshot: HostedPracticeSnapshot(
                connection: .writable,
                activity: try decodeCodingActivity(),
                boundSpecialty: .leetcode
            )
        )
    }
}

private func decodeCodingActivity() throws -> LiveActivityProjection {
    let data = Data(
        """
        {
          "protocolVersion": 1,
          "serverTime": 1000000,
          "ownerRevision": 8,
          "workbench": {
            "id": "workbench-1",
            "revision": 5,
            "openedPacificDate": "2026-08-11",
            "openedAt": 900000
          },
          "focus": {
            "activityId": "activity-code",
            "sessionId": "session-1",
            "focusedAt": 990000
          },
          "session": {
            "id": "session-1",
            "label": "Coding practice",
            "activityIds": ["activity-code"],
            "allocatedSeconds": 2400,
            "revision": 1,
            "timer": null
          },
          "activity": {
            "id": "activity-code",
            "questionId": "1",
            "date": "2026-08-11",
            "source": "fixture",
            "type": "leetcode",
            "title": "Two Sum",
            "prompt": "Two Sum",
            "allocatedSeconds": 2400,
            "sessionId": "session-1",
            "lifecycle": "planned",
            "revision": 1,
            "timer": {
              "accumulatedSeconds": 0,
              "startedAt": null,
              "runningSince": null,
              "completed": false,
              "completedAt": null,
              "revision": 0
            },
            "result": {
              "value": null,
              "revision": 0
            },
            "textEvidenceSatisfied": false
          },
          "lease": {
            "active": false,
            "holderPresent": false,
            "expiresAt": null
          },
          "pairs": [],
          "clips": []
        }
        """.utf8
    )
    return try JSONDecoder().decode(LiveActivityProjection.self, from: data)
}

private actor RunGate {
    private var continuation: CheckedContinuation<CodingProcessResult, Error>?

    func wait() async throws -> CodingProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(_ result: CodingProcessResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class FirstRunBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var callCount = 0

    func nextResult() async throws -> CodingProcessResult {
        let (count, pendingStart): (Int, CheckedContinuation<Void, Never>?) = lock.withLock {
            callCount += 1
            let pendingStart: CheckedContinuation<Void, Never>?
            if !didStart {
                didStart = true
                pendingStart = startedContinuation
                startedContinuation = nil
            } else {
                pendingStart = nil
            }
            return (callCount, pendingStart)
        }
        pendingStart?.resume()
        if count == 1 {
            try await Task.sleep(for: .seconds(60))
            return CodingProcessResult(
                exitCode: 1,
                stdout: "superseded-first-run",
                stderr: ""
            )
        }
        return CodingProcessResult(
            exitCode: 0,
            stdout: "Locally verified: Quick suite passed 1/1 tests. This is not a LeetCode Accepted verdict.\n",
            stderr: ""
        )
    }

    func waitUntilStarted() async {
        if lock.withLock({ didStart }) {
            return
        }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if didStart {
                    return true
                }
                startedContinuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }
}

private final class ArgumentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[String]] = []

    func append(_ arguments: [String]) {
        lock.withLock { lists.append(arguments) }
    }

    var snapshot: [[String]] {
        lock.withLock { lists }
    }
}

private func invocationID(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--invocation-id"),
          index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 1,
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition was not met before timeout")
    struct Timeout: Error {}
    throw Timeout()
}
