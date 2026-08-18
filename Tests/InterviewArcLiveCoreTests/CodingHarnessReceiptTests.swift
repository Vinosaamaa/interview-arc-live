import XCTest

@testable import InterviewArcLiveCore

final class CodingHarnessReceiptTests: XCTestCase {
    func testSuccessfulRunIsLocallyVerifiedNeverAccepted() {
        let receipt = CodingHarnessReceipt.parse(
            identity: "run-1",
            commandClass: .quickRun,
            exitCode: 0,
            stdout: """
            Suite: Quick
            Locally verified: Quick suite passed 12/12 tests. This is not a LeetCode Accepted verdict.
            """,
            stderr: ""
        )

        XCTAssertEqual(receipt.outcome.label, "Locally verified")
        XCTAssertEqual(receipt.summaryLine, "Locally verified · 12 / 12")
        XCTAssertNotEqual(receipt.outcome.label, "Accepted")
        XCTAssertFalse(receipt.outcome.label.localizedCaseInsensitiveContains("accepted"))
        if case .locallyVerified(let passed, let total) = receipt.outcome {
            XCTAssertEqual(passed, 12)
            XCTAssertEqual(total, 12)
        } else {
            XCTFail("Expected a locally verified outcome")
        }
    }

    func testFailedRunKeepsLocalVerificationLanguage() {
        let receipt = CodingHarnessReceipt.parse(
            identity: "run-2",
            commandClass: .fullRun,
            exitCode: 1,
            stdout: "Local verification failed: Full local suite passed 9/12 tests.\n",
            stderr: ""
        )

        XCTAssertEqual(receipt.outcome.label, "Local verification failed")
        XCTAssertEqual(receipt.summaryLine, "Local verification failed · 9 / 12")
        XCTAssertFalse(receipt.outcome.label.localizedCaseInsensitiveContains("accepted"))
    }

    func testRunningReceiptIsNotAccepted() {
        let receipt = CodingHarnessReceipt.running(
            identity: "run-live",
            commandClass: .quickRun
        )
        XCTAssertEqual(receipt.outcome.label, "Running")
        XCTAssertEqual(receipt.summaryLine, "Running")
        XCTAssertFalse(receipt.outcome.isSuccess)
        XCTAssertFalse(receipt.outcome.label.localizedCaseInsensitiveContains("accepted"))
    }

    func testMissingHarnessIsNotReady() {
        let receipt = CodingHarnessReceipt.notReady(
            identity: "run-3",
            commandClass: .quickRun
        )
        XCTAssertEqual(receipt.outcome.label, "Local harness is not ready")
        XCTAssertEqual(receipt.exitCode, 75)

        let preparing = CodingHarnessReceipt.parse(
            identity: "run-4",
            commandClass: .quickRun,
            exitCode: 75,
            stdout: "",
            stderr: "Test harness is still preparing; run this command again shortly."
        )
        XCTAssertEqual(preparing.outcome.label, "Local harness is not ready")
    }
}
