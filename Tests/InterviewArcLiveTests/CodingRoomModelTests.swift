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
}
