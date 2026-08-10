import CoreGraphics
import XCTest
@testable import InterviewArcLive

final class SystemDesignRoomLayoutTests: XCTestCase {
    func testSupportedWidthsKeepTheApprovedTurnlineBoardBalance() {
        for width: CGFloat in [1_080, 1_197, 1_600] {
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

    func testWideWindowDoesNotCapTheTurnlineBelowTheApprovedFraction() {
        let width: CGFloat = 1_600

        XCTAssertEqual(
            FullRoomLayout.turnlineIdealWidth(for: width),
            592,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FullRoomLayout.boardIdealWidth(for: width),
            1_008,
            accuracy: 0.001
        )
    }

    func testMinimumWindowRetainsAUsableWorkspaceAndActionTargets() {
        XCTAssertEqual(
            FullRoomLayout.questionBandHeight(forLineCount: 1),
            148
        )
        XCTAssertEqual(
            FullRoomLayout.questionBandHeight(forLineCount: 2),
            196
        )
        XCTAssertEqual(FullRoomLayout.questionBandMaximumHeight, 196)
        XCTAssertEqual(FullRoomLayout.minimumWindowHeight, 742)
        XCTAssertEqual(
            FullRoomLayout.minimumWorkspaceHeight(
                for: FullRoomLayout.minimumWindowHeight,
                questionLineCount: FullRoomLayout.questionLineLimit
            ),
            FullRoomLayout.requiredWorkspaceHeight
        )
        XCTAssertGreaterThanOrEqual(
            FullRoomLayout.minimumWorkspaceHeight(
                for: FullRoomLayout.minimumWindowHeight,
                questionLineCount: 1
            ),
            FullRoomLayout.requiredWorkspaceHeight
        )
        XCTAssertGreaterThanOrEqual(FullRoomLayout.minimumActionHitTarget, 44)
        XCTAssertGreaterThanOrEqual(
            FullRoomLayout.floorRailHeight,
            FullRoomLayout.minimumActionHitTarget
        )
        XCTAssertGreaterThanOrEqual(FullRoomLayout.questionLineLimit, 2)
        XCTAssertEqual(
            FullRoomLayout.questionBandMinimumHeight,
            FullRoomLayout.questionBandHeight(forLineCount: 1)
        )
        XCTAssertEqual(FullRoomLayout.questionTitleSize, 40)
        XCTAssertEqual(FullRoomLayout.turnlineHorizontalPadding, 64)
        XCTAssertEqual(FullRoomLayout.turnlineEntryGap, 42)
        XCTAssertEqual(FullRoomLayout.turnlineBodyFontSize, 24)
        XCTAssertEqual(FullRoomLayout.floorRailHeight, 96)
        XCTAssertEqual(FullRoomLayout.floorContentHorizontalPadding, 48)
        XCTAssertEqual(FullRoomLayout.floorOutlineHorizontalInset, 24)
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

    func testDefaultWidthKeepsWideHeaderUnderAttention() {
        let state = FullRoomHeaderLayout.state(
            windowWidth: FullRoomLayout.defaultWindowWidth,
            hasSpeechAttention: true,
            hasRoomAttention: true
        )
        XCTAssertEqual(state.attention, .speechAndRoom)
        XCTAssertFalse(state.usesAttentionCompactHeader)
    }

    func testHeaderPresentationIsWideAt1197And1600ForEveryAttentionState() {
        for width: CGFloat in [1_197, 1_600] {
            for (speech, room) in [
                (false, false),
                (true, false),
                (false, true),
                (true, true),
            ] {
                let state = FullRoomHeaderLayout.state(
                    windowWidth: width,
                    hasSpeechAttention: speech,
                    hasRoomAttention: room
                )

                XCTAssertEqual(state.presentation, .wide)
            }
        }
    }

    func testMinimumWidthKeepsWideHeaderWithoutAttentionAndCompactWithIt() {
        let normal = FullRoomHeaderLayout.state(
            windowWidth: 1_080,
            hasSpeechAttention: false,
            hasRoomAttention: false
        )
        let attention = FullRoomHeaderLayout.state(
            windowWidth: 1_080,
            hasSpeechAttention: true,
            hasRoomAttention: true
        )

        XCTAssertEqual(normal.presentation, .wide)
        XCTAssertEqual(attention.presentation, .compact)
        XCTAssertTrue(
            FullRoomHeaderAccessibility.personaLabel.contains("Staff Engineer")
        )
        XCTAssertEqual(
            FullRoomHeaderAccessibility.privacyLabel,
            "Private local session"
        )
    }

    func testWaveformUsesTheRailWithoutPretendingToBeRecordedAudio() {
        for width: CGFloat in [140, 600, 900] {
            let positions = FullRoomWaveformLayout.barXPositions(
                width: width,
                levelCount: 30
            )

            XCTAssertEqual(positions.count, 30)
            XCTAssertEqual(
                positions.first ?? .nan,
                FullRoomWaveformLayout.horizontalInset,
                accuracy: 0.001
            )
            XCTAssertEqual(
                positions.last ?? .nan,
                width * FullRoomWaveformLayout.traceCoverageFraction
                    - FullRoomWaveformLayout.horizontalInset,
                accuracy: 0.001
            )
            XCTAssertTrue(
                zip(positions, positions.dropFirst()).allSatisfy { lhs, rhs in
                    lhs < rhs
                }
            )
            XCTAssertGreaterThanOrEqual(positions.first ?? -1, 0)
            XCTAssertLessThanOrEqual(positions.last ?? .infinity, width)
        }
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
