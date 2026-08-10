import XCTest
@testable import InterviewArcLive

final class SystemDesignRoomLayoutTests: XCTestCase {
    func testMinimumAndDefaultWidthsKeepTheApprovedTurnlineBoardBalance() {
        for width in [
            FullRoomLayout.minimumWindowWidth,
            FullRoomLayout.defaultWindowWidth,
        ] {
            let turnline = FullRoomLayout.turnlineIdealWidth(for: width)
            let board = FullRoomLayout.boardIdealWidth(for: width)

            XCTAssertEqual(
                turnline / width,
                FullRoomLayout.turnlineWidthFraction,
                accuracy: 0.001
            )
            XCTAssertGreaterThanOrEqual(turnline, FullRoomLayout.turnlineMinimumWidth)
            XCTAssertGreaterThanOrEqual(board, FullRoomLayout.boardMinimumWidth)
            XCTAssertEqual(turnline + board, width, accuracy: 0.001)
        }
    }

    func testMinimumWindowRetainsAUsableWorkspaceAndActionTargets() {
        XCTAssertGreaterThanOrEqual(
            FullRoomLayout.minimumWorkspaceHeight(
                for: FullRoomLayout.minimumWindowHeight
            ),
            420
        )
        XCTAssertGreaterThanOrEqual(FullRoomLayout.minimumActionHitTarget, 44)
        XCTAssertGreaterThanOrEqual(
            FullRoomLayout.floorRailHeight,
            FullRoomLayout.minimumActionHitTarget
        )
        XCTAssertGreaterThanOrEqual(FullRoomLayout.questionLineLimit, 2)
    }

    func testCandidateTextMeetsWCAGBodyContrastAcrossRoomSurfaces() {
        XCTAssertGreaterThanOrEqual(
            LivePalette.candidateTextToken.contrastRatio(
                against: LivePalette.paperToken
            ),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            LivePalette.candidateTextToken.contrastRatio(
                against: LivePalette.roomToken
            ),
            4.5
        )
    }

    func testFullRoomAccessibilityIdentifiersAreStableAndUnique() {
        XCTAssertEqual(
            Set(FullRoomAccessibility.allIdentifiers).count,
            FullRoomAccessibility.allIdentifiers.count
        )
        XCTAssertEqual(FullRoomAccessibility.question, "full-room-question")
        XCTAssertEqual(FullRoomAccessibility.turnline, "full-room-turnline")
        XCTAssertEqual(FullRoomAccessibility.board, "full-room-board")
        XCTAssertEqual(FullRoomAccessibility.floorRail, "full-room-floor-rail")
        XCTAssertEqual(
            FullRoomAccessibility.primaryAction,
            "full-room-primary-action"
        )
    }
}
