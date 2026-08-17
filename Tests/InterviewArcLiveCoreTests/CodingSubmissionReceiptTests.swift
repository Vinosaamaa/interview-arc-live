import XCTest

@testable import InterviewArcLiveCore

final class CodingSubmissionReceiptTests: XCTestCase {
    func testAcceptedVerdictIsTheOnlyAcceptedLabel() {
        let receipt = CodingSubmissionReceipt.parse(
            invocationID: "live-submit-1",
            command: .submit,
            exitCode: 0,
            stdout: """
            {
              "ok": true,
              "invocationId": "live-submit-1",
              "result": { "verdict": "Accepted" }
            }
            """,
            stderr: ""
        )
        XCTAssertEqual(receipt.outcome, .accepted)
        XCTAssertEqual(receipt.summaryLine, "Accepted")
        XCTAssertTrue(receipt.outcome.isAccepted)
    }

    func testWrongAnswerIsNeverRelabeledAccepted() {
        let receipt = CodingSubmissionReceipt.parse(
            invocationID: "live-submit-2",
            command: .submit,
            exitCode: 0,
            stdout: """
            {
              "ok": true,
              "invocationId": "live-submit-2",
              "result": { "verdict": "Wrong Answer" }
            }
            """,
            stderr: ""
        )
        XCTAssertEqual(receipt.outcome, .rejected(verdict: "Wrong Answer"))
        XCTAssertEqual(receipt.summaryLine, "Wrong Answer")
        XCTAssertFalse(receipt.outcome.isAccepted)
        XCTAssertFalse(receipt.summaryLine.localizedCaseInsensitiveContains("accepted"))
    }

    func testFailureEnvelopeUsesControllerCode() {
        let receipt = CodingSubmissionReceipt.parse(
            invocationID: "live-submit-3",
            command: .retry,
            exitCode: 1,
            stdout: "",
            stderr: """
            {
              "ok": false,
              "invocationId": "live-submit-3",
              "error": { "code": "preflight_stale", "message": "The preflight receipt is stale." }
            }
            """
        )
        XCTAssertEqual(
            receipt.outcome,
            .failed(code: "preflight_stale", message: "The preflight receipt is stale.")
        )
    }

    func testEmptyOutputIsAmbiguous() {
        let receipt = CodingSubmissionReceipt.parse(
            invocationID: "live-submit-4",
            command: .submit,
            exitCode: 1,
            stdout: "",
            stderr: ""
        )
        if case .ambiguous = receipt.outcome {
            XCTAssertEqual(receipt.invocationID, "live-submit-4")
        } else {
            XCTFail("Empty controller output must stay ambiguous")
        }
    }

    func testPendingReceiptStaysAmbiguous() {
        let receipt = CodingSubmissionReceipt.parse(
            invocationID: "live-submit-5",
            command: .receipt,
            exitCode: 1,
            stdout: "",
            stderr: """
            {
              "ok": false,
              "invocationId": "live-submit-5",
              "error": {
                "code": "controller_receipt_pending",
                "message": "The invocation was reserved but no terminal receipt is available."
              }
            }
            """
        )
        if case .ambiguous = receipt.outcome {
            XCTAssertFalse(receipt.outcome.isAccepted)
        } else {
            XCTFail("Pending receipts must stay ambiguous")
        }
    }

    func testSubmittingPlaceholderIsNotAccepted() {
        let receipt = CodingSubmissionReceipt.submitting(
            invocationID: "live-submit-6",
            command: .submit
        )
        XCTAssertEqual(receipt.summaryLine, "Submitting · waiting for LeetCode")
        XCTAssertFalse(receipt.outcome.isAccepted)
    }
}
