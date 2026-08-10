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

    func testMinimumWidthUsesCompactHeaderForSpeechAndRoomAttention() {
        let normal = FullRoomHeaderLayout.state(
            windowWidth: FullRoomLayout.minimumWindowWidth,
            hasSpeechAttention: false,
            hasRoomAttention: false
        )
        XCTAssertEqual(normal.attention, .none)
        XCTAssertFalse(normal.usesAttentionCompactHeader)

        let speech = FullRoomHeaderLayout.state(
            windowWidth: FullRoomLayout.minimumWindowWidth,
            hasSpeechAttention: true,
            hasRoomAttention: false
        )
        XCTAssertEqual(speech.attention, .speech)
        XCTAssertTrue(speech.usesAttentionCompactHeader)

        let room = FullRoomHeaderLayout.state(
            windowWidth: FullRoomLayout.minimumWindowWidth,
            hasSpeechAttention: false,
            hasRoomAttention: true
        )
        XCTAssertEqual(room.attention, .room)
        XCTAssertTrue(room.usesAttentionCompactHeader)

        let combined = FullRoomHeaderLayout.state(
            windowWidth: FullRoomLayout.minimumWindowWidth,
            hasSpeechAttention: true,
            hasRoomAttention: true
        )
        XCTAssertEqual(combined.attention, .speechAndRoom)
        XCTAssertTrue(combined.usesAttentionCompactHeader)
    }

    func testDefaultWidthStillLetsViewThatFitsChooseTheHeader() {
        let state = FullRoomHeaderLayout.state(
            windowWidth: FullRoomLayout.defaultWindowWidth,
            hasSpeechAttention: true,
            hasRoomAttention: true
        )
        XCTAssertEqual(state.attention, .speechAndRoom)
        XCTAssertFalse(state.usesAttentionCompactHeader)
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
        XCTAssertEqual(FullRoomAccessibility.collapse, "full-room-collapse")
        XCTAssertEqual(
            FullRoomAccessibility.primaryAction,
            "full-room-primary-action"
        )
        XCTAssertFalse(FullRoomHeaderAccessibility.roomStatusLabel.isEmpty)
        XCTAssertFalse(FullRoomHeaderAccessibility.personaLabel.isEmpty)
        XCTAssertFalse(FullRoomHeaderAccessibility.privacyLabel.isEmpty)
        XCTAssertFalse(FullRoomHeaderAccessibility.collapseLabel.isEmpty)
    }
}
