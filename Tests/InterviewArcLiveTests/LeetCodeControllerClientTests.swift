import Foundation
import XCTest

import InterviewArcLiveCore
@testable import InterviewArcLive

final class LeetCodeControllerClientTests: XCTestCase {
    func testSubmitBuildsArgvWithJavaFileTitleAndInvocationID() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let invocationID = LeetCodeControllerClient.makeInvocationID()
        let probe = ExecuteProbe()

        let receipt = await LeetCodeControllerClient.submit(
            fixture.request,
            javaFile: fixture.javaFile,
            invocationID: invocationID,
            command: .submit,
            nodeExecutable: fixture.node,
            execute: { executable, arguments, directory in
                probe.record(executable: executable, arguments: arguments, directory: directory)
                return CodingProcessResult(
                    exitCode: 0,
                    stdout: acceptedEnvelope(invocationID: invocationID),
                    stderr: ""
                )
            }
        )

        XCTAssertEqual(probe.calls.count, 1)
        let arguments = try XCTUnwrap(probe.calls.first?.arguments)
        XCTAssertEqual(
            arguments,
            [
                LeetCodeControllerClient.controllerScriptURL(
                    repositoryRoot: fixture.root
                ).path,
                "submit",
                "https://leetcode.com/problems/two-sum/",
                fixture.javaFile.path,
                "--title",
                "Two Sum",
                "--invocation-id",
                invocationID,
            ]
        )
        XCTAssertEqual(probe.calls.first?.directory, fixture.root)
        XCTAssertEqual(receipt.outcome, .accepted)
        XCTAssertTrue(receipt.outcome.isAccepted)
        assertPublicSafe(arguments)
    }

    func testRetryUsesDistinctInvocationIDAndRetryCommand() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let submitID = LeetCodeControllerClient.makeInvocationID()
        let retryID = LeetCodeControllerClient.makeInvocationID()
        XCTAssertNotEqual(submitID, retryID)
        let probe = ExecuteProbe()

        _ = await LeetCodeControllerClient.submit(
            fixture.request,
            javaFile: fixture.javaFile,
            invocationID: submitID,
            command: .submit,
            nodeExecutable: fixture.node,
            execute: { executable, arguments, directory in
                probe.record(executable: executable, arguments: arguments, directory: directory)
                return CodingProcessResult(
                    exitCode: 0,
                    stdout: acceptedEnvelope(invocationID: submitID),
                    stderr: ""
                )
            }
        )
        let retryReceipt = await LeetCodeControllerClient.submit(
            fixture.request,
            javaFile: fixture.javaFile,
            invocationID: retryID,
            command: .retry,
            nodeExecutable: fixture.node,
            execute: { executable, arguments, directory in
                probe.record(executable: executable, arguments: arguments, directory: directory)
                return CodingProcessResult(
                    exitCode: 0,
                    stdout: acceptedEnvelope(invocationID: retryID),
                    stderr: ""
                )
            }
        )

        XCTAssertEqual(probe.calls.count, 2)
        let submitArguments = try XCTUnwrap(probe.calls.first?.arguments)
        XCTAssertEqual(submitArguments[1], "submit")
        XCTAssertTrue(submitArguments.contains(submitID))
        let retryArguments = try XCTUnwrap(probe.calls.last?.arguments)
        XCTAssertEqual(
            retryArguments,
            [
                LeetCodeControllerClient.controllerScriptURL(
                    repositoryRoot: fixture.root
                ).path,
                "retry",
                "https://leetcode.com/problems/two-sum/",
                fixture.javaFile.path,
                "--title",
                "Two Sum",
                "--invocation-id",
                retryID,
            ]
        )
        XCTAssertFalse(retryArguments.contains(submitID))
        XCTAssertEqual(retryReceipt.invocationID, retryID)
        assertPublicSafe(retryArguments)
    }

    func testFailureJSONOnStderrIsFailedNeverAccepted() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let invocationID = LeetCodeControllerClient.makeInvocationID()

        let receipt = await LeetCodeControllerClient.submit(
            fixture.request,
            javaFile: fixture.javaFile,
            invocationID: invocationID,
            command: .submit,
            nodeExecutable: fixture.node,
            execute: { _, _, _ in
                CodingProcessResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: """
                    {
                      "ok": false,
                      "invocationId": "\(invocationID)",
                      "error": {
                        "code": "preflight_stale",
                        "message": "The preflight receipt is stale."
                      }
                    }
                    """
                )
            }
        )

        XCTAssertEqual(
            receipt.outcome,
            .failed(code: "preflight_stale", message: "The preflight receipt is stale.")
        )
        XCTAssertFalse(receipt.outcome.isAccepted)
        if case .accepted = receipt.outcome {
            XCTFail("Failure envelopes must never become Accepted")
        }
    }

    func testSubmitRecoveringAmbiguousOutputReadsReceiptOnceWithSameInvocationID() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let invocationID = LeetCodeControllerClient.makeInvocationID()
        let probe = ExecuteProbe()

        let receipt = await LeetCodeControllerClient.submitRecoveringAmbiguousOutput(
            fixture.request,
            javaFile: fixture.javaFile,
            invocationID: invocationID,
            command: .submit,
            nodeExecutable: fixture.node,
            execute: { executable, arguments, directory in
                probe.record(executable: executable, arguments: arguments, directory: directory)
                if arguments.contains("receipt") {
                    return CodingProcessResult(
                        exitCode: 0,
                        stdout: """
                        {
                          "ok": true,
                          "invocationId": "\(invocationID)",
                          "result": { "verdict": "Wrong Answer" }
                        }
                        """,
                        stderr: ""
                    )
                }
                return CodingProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        XCTAssertEqual(probe.calls.count, 2)
        let submitArguments = try XCTUnwrap(probe.calls.first?.arguments)
        let receiptArguments = try XCTUnwrap(probe.calls.last?.arguments)
        XCTAssertEqual(submitArguments[1], "submit")
        XCTAssertEqual(
            receiptArguments,
            [
                LeetCodeControllerClient.controllerScriptURL(
                    repositoryRoot: fixture.root
                ).path,
                "receipt",
                "--invocation-id",
                invocationID,
            ]
        )
        XCTAssertEqual(receipt.invocationID, invocationID)
        XCTAssertEqual(receipt.outcome, .rejected(verdict: "Wrong Answer"))
        XCTAssertFalse(receipt.outcome.isAccepted)
        XCTAssertTrue(submitArguments.contains(invocationID))
        assertPublicSafe(submitArguments)
        assertPublicSafe(receiptArguments)
    }

    func testMakeInvocationIDIsLowercaseAndMatchesControllerRegex() {
        let invocationID = LeetCodeControllerClient.makeInvocationID()
        XCTAssertEqual(invocationID, invocationID.lowercased())
        XCTAssertNotNil(invocationID.wholeMatch(of: /^[a-z0-9][a-z0-9._-]{0,127}$/))
        XCTAssertTrue(invocationID.hasPrefix("live-submit-"))
    }

    func testMissingControllerScriptReturnsFailedReceiptWithoutExecuting() async throws {
        let fixture = try makeFixture(withControllerScript: false)
        defer { fixture.remove() }
        let invocationID = LeetCodeControllerClient.makeInvocationID()
        let probe = ExecuteProbe()

        let receipt = await LeetCodeControllerClient.submit(
            fixture.request,
            javaFile: fixture.javaFile,
            invocationID: invocationID,
            command: .submit,
            nodeExecutable: fixture.node,
            execute: { executable, arguments, directory in
                probe.record(executable: executable, arguments: arguments, directory: directory)
                return CodingProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        XCTAssertEqual(probe.calls.count, 0)
        XCTAssertEqual(
            receipt.outcome,
            .failed(
                code: nil,
                message: LeetCodeControllerError.controllerMissing.errorDescription
                    ?? "Open LeetCode needs a linked Interview Arc checkout with the checked-in Playwright controller."
            )
        )
        XCTAssertFalse(receipt.outcome.isAccepted)
    }
}

private struct ControllerClientFixture {
    var root: URL
    var request: LeetCodeControllerRequest
    var javaFile: URL
    var node: URL

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeFixture(
    withControllerScript: Bool = true
) throws -> ControllerClientFixture {
    let root = URL(
        fileURLWithPath: "/tmp/live-controller-client-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if withControllerScript {
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("export {}\n".utf8).write(
            to: scripts.appendingPathComponent("leetcode-playwright-controller.mjs")
        )
    }
    let javaFile = root.appendingPathComponent("0001-two-sum.java")
    try Data("class Solution {}\n".utf8).write(to: javaFile)
    let problemURL = URL(string: "https://leetcode.com/problems/two-sum/")!
    return ControllerClientFixture(
        root: root,
        request: LeetCodeControllerRequest(
            repositoryRoot: root,
            problemURL: problemURL,
            title: "Two Sum"
        ),
        javaFile: javaFile,
        node: root.appendingPathComponent("fixture-node")
    )
}

private func acceptedEnvelope(invocationID: String) -> String {
    """
    {
      "ok": true,
      "invocationId": "\(invocationID)",
      "result": { "verdict": "Accepted" }
    }
    """
}

private func assertPublicSafe(_ arguments: [String]) {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertFalse(arguments.contains { $0.hasPrefix(home) })
    XCTAssertFalse(arguments.contains { $0.contains("browser-profiles") })
    XCTAssertFalse(arguments.contains { $0.localizedCaseInsensitiveContains("cookie") })
    XCTAssertFalse(arguments.contains { $0.localizedCaseInsensitiveContains("credential") })
}

private final class ExecuteProbe: @unchecked Sendable {
    struct Call {
        var executable: URL
        var arguments: [String]
        var directory: URL
    }

    private(set) var calls: [Call] = []

    func record(executable: URL, arguments: [String], directory: URL) {
        calls.append(Call(executable: executable, arguments: arguments, directory: directory))
    }
}
