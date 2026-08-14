import CoreGraphics
import XCTest
@testable import InterviewArcLive

final class SystemDesignRoomLayoutTests: XCTestCase {
    func testSupportedWidthsUseTheDefaultResizableTurnlineBoardComposition() {
        let contracts: [(
            total: CGFloat,
            turnline: CGFloat,
            board: CGFloat
        )] = [
            (800, 272, 528),
            (1_180, 401.2, 778.8),
            (1_600, 544, 1_056),
        ]

        for contract in contracts {
            let width = contract.total
            let widths = FullRoomLayout.workspaceWidths(for: width)

            XCTAssertEqual(
                widths.turnlineWidth,
                contract.turnline,
                accuracy: 0.001
            )
            XCTAssertEqual(
                widths.boardWidth,
                contract.board,
                accuracy: 0.001
            )
            XCTAssertEqual(
                widths.turnlineWidth / width,
                FullRoomLayout.turnlineWidthFraction,
                accuracy: 0.001
            )
            XCTAssertEqual(
                widths.boardWidth / width,
                FullRoomLayout.boardWidthFraction,
                accuracy: 0.001
            )
            XCTAssertGreaterThanOrEqual(
                widths.turnlineWidth,
                FullRoomLayout.turnlineMinimumWidth
            )
            XCTAssertGreaterThanOrEqual(
                widths.boardWidth,
                FullRoomLayout.boardMinimumWidth
            )
            XCTAssertEqual(widths.composedWidth, width, accuracy: 0.001)
            XCTAssertEqual(widths.totalWidth, width)
            XCTAssertEqual(widths.visualDividerWidth, 1)
        }
        XCTAssertEqual(
            FullRoomLayout.boardWidthFraction,
            0.66,
            accuracy: 0.001
        )
    }

    func testWideWindowKeepsTheDefaultSplitUntilTheUserDragsIt() {
        let width: CGFloat = 1_600

        XCTAssertEqual(
            FullRoomLayout.turnlineIdealWidth(for: width),
            544,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FullRoomLayout.boardIdealWidth(for: width),
            1_056,
            accuracy: 0.001
        )
    }

    func testUserSplitClampsToReadablePaneMinima() {
        let width: CGFloat = 800

        XCTAssertEqual(
            FullRoomLayout.workspaceWidths(
                for: width,
                preferredTurnlineWidth: 120
            ).turnlineWidth,
            FullRoomLayout.turnlineMinimumWidth
        )
        XCTAssertEqual(
            FullRoomLayout.workspaceWidths(
                for: width,
                preferredTurnlineWidth: 700
            ).boardWidth,
            FullRoomLayout.boardMinimumWidth
        )
        XCTAssertEqual(FullRoomLayout.workspaceDividerHitWidth, 13)
    }

    func testDividerCommitsStableWorkspaceTranslationExactlyOnce() {
        let workspaceWidth: CGFloat = 1_180
        let baseWidth = FullRoomLayout.turnlineBaseWidth(
            for: workspaceWidth,
            preferredTurnlineWidth: 420
        )
        let stableWidths = FullRoomLayout.workspaceWidths(
            for: workspaceWidth,
            preferredTurnlineWidth: baseWidth
        )
        let preview = FullRoomLayout.splitDragPreview(
            baseWidth: baseWidth,
            dragTranslation: 60,
            workspaceWidth: workspaceWidth
        )

        XCTAssertEqual(baseWidth, 420, accuracy: 0.001)
        XCTAssertEqual(stableWidths.turnlineWidth, 420, accuracy: 0.001)
        XCTAssertEqual(stableWidths.boardWidth, 760, accuracy: 0.001)
        XCTAssertEqual(preview.translation, 60, accuracy: 0.001)
        XCTAssertEqual(preview.proposedTurnlineWidth, 480, accuracy: 0.001)
        XCTAssertEqual(
            FullRoomLayout.committedTurnlineWidth(
                baseWidth: baseWidth,
                dragTranslation: 60,
                workspaceWidth: workspaceWidth
            ),
            480,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FullRoomLayout.workspaceWidths(
                for: workspaceWidth,
                preferredTurnlineWidth: 480
            ).turnlineWidth,
            480,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FullRoomLayout.workspaceCoordinateSpaceName,
            "system-design-workspace"
        )
    }

    func testDividerPreviewClampsWithoutRelayingOutEitherPane() {
        let workspaceWidth: CGFloat = 800
        let baseWidth = FullRoomLayout.turnlineBaseWidth(for: workspaceWidth)
        let stableWidths = FullRoomLayout.workspaceWidths(for: workspaceWidth)
        let preview = FullRoomLayout.splitDragPreview(
            baseWidth: baseWidth,
            dragTranslation: 400,
            workspaceWidth: workspaceWidth
        )

        XCTAssertEqual(stableWidths.turnlineWidth, 272, accuracy: 0.001)
        XCTAssertEqual(stableWidths.boardWidth, 528, accuracy: 0.001)
        XCTAssertEqual(
            preview.proposedTurnlineWidth,
            workspaceWidth - FullRoomLayout.boardMinimumWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            preview.translation,
            preview.proposedTurnlineWidth - baseWidth,
            accuracy: 0.001
        )
    }

    func testMinimumWindowRetainsAUsableWorkspaceAndActionTargets() {
        XCTAssertEqual(
            FullRoomLayout.questionBandHeight(forLineCount: 1),
            132
        )
        XCTAssertEqual(
            FullRoomLayout.questionBandHeight(forLineCount: 2),
            170
        )
        XCTAssertEqual(FullRoomLayout.questionBandMaximumHeight, 170)
        XCTAssertEqual(FullRoomLayout.minimumWindowWidth, 800)
        XCTAssertEqual(FullRoomLayout.minimumWindowHeight, 500)
        XCTAssertGreaterThanOrEqual(
            FullRoomLayout.minimumWorkspaceHeight(
                for: FullRoomLayout.minimumWindowHeight,
                questionLineCount: FullRoomLayout.questionLineLimit
            ),
            FullRoomLayout.requiredWorkspaceHeight
        )
        XCTAssertGreaterThanOrEqual(
            FullRoomLayout.minimumTurnlineHeight(
                for: FullRoomLayout.minimumWindowHeight,
                questionLineCount: FullRoomLayout.questionLineLimit
            ),
            FullRoomLayout.requiredTurnlineHeight
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
        XCTAssertEqual(FullRoomLayout.headerHeight, 50)
        XCTAssertEqual(FullRoomLayout.questionTitleSize, 32)
        XCTAssertEqual(FullRoomLayout.turnlineHorizontalPadding, 32)
        XCTAssertEqual(FullRoomLayout.turnlineEntryGap, 24)
        XCTAssertEqual(FullRoomLayout.turnlineBodyFontSize, 20)
        XCTAssertEqual(FullRoomLayout.floorRailHeight, 55)
        XCTAssertEqual(FullRoomLayout.floorCompactStatusWidth, 112)
        XCTAssertEqual(FullRoomLayout.floorCompactWaveformWidth, 80)
        XCTAssertEqual(FullRoomLayout.floorCompactSpacing, 8)
        XCTAssertEqual(FullRoomLayout.floorCompactHorizontalPadding, 16)
        XCTAssertEqual(FullRoomLayout.floorCompactMaximumRequiredWidth, 623)
        XCTAssertLessThanOrEqual(
            FullRoomLayout.floorCompactMaximumRequiredWidth,
            FullRoomLayout.minimumWindowWidth
        )
        XCTAssertEqual(FullRoomLayout.floorContentHorizontalPadding, 24)
        XCTAssertEqual(FullRoomLayout.floorOutlineHorizontalInset, 16)
        XCTAssertEqual(FullRoomLayout.floorOutlineVerticalInset, 4)
        XCTAssertLessThanOrEqual(
            FullRoomLayout.minimumActionHitTarget,
            FullRoomLayout.floorRailHeight
                - FullRoomLayout.floorOutlineVerticalInset * 2
        )
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

    func testMinimumWidthAlwaysUsesCompactHeader() {
        let normal = FullRoomHeaderLayout.state(
            windowWidth: FullRoomLayout.minimumWindowWidth,
            hasSpeechAttention: false,
            hasRoomAttention: false
        )
        XCTAssertEqual(normal.attention, .none)
        XCTAssertTrue(normal.usesAttentionCompactHeader)

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

        let boundedAttention = FullRoomHeaderLayout.state(
            windowWidth: FullRoomHeaderStatusLayout.minimumWideHeaderWidth,
            hasSpeechAttention: true,
            hasRoomAttention: true
        )
        XCTAssertEqual(boundedAttention.presentation, .compact)

        let fittingWideAttention = FullRoomHeaderLayout.state(
            windowWidth: FullRoomHeaderStatusLayout.minimumWideHeaderWidth + 1,
            hasSpeechAttention: true,
            hasRoomAttention: true
        )
        XCTAssertEqual(fittingWideAttention.presentation, .wide)
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

    func testIntermediateWidthKeepsCompactHeaderWithAndWithoutAttention() {
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

        XCTAssertEqual(normal.presentation, .compact)
        XCTAssertEqual(attention.presentation, .compact)
        XCTAssertTrue(
            FullRoomHeaderAccessibility.personaLabel.contains("Staff Engineer")
        )
        XCTAssertEqual(
            FullRoomHeaderAccessibility.privacyLabel,
            "Private local session"
        )
    }

    func testHeaderVisualLabelsAreAtomicAndTruthful() {
        XCTAssertEqual(
            FullRoomHeaderLabels.roomStatus(
                statusMessage: "Restoring local session…"
            ),
            "System design · Restoring local session…"
        )
        XCTAssertEqual(FullRoomHeaderLabels.compactRoom, "System design")
        XCTAssertEqual(FullRoomHeaderLabels.widePersona, "Mara · Staff Engineer")
        XCTAssertEqual(FullRoomHeaderLabels.compactPersona, "Mara")

        for width: CGFloat in [1_080, 1_180] {
            let status = FullRoomHeaderStatusLayout.presentation(
                headerPresentation: .wide,
                windowWidth: width,
                statusMessage: "Ready to record"
            )
            XCTAssertEqual(status.style, .wideInline)
            XCTAssertEqual(status.visibleText, "System design · Ready to record")
            XCTAssertEqual(status.accessibilityValue, "Ready to record")
            XCTAssertEqual(status.lineLimit, 1)
            XCTAssertNil(status.frameWidth)
        }
    }

    func testLongestOperationalStatusUsesBoundedReadableWideFallback() {
        let longestStatus = "Groq key available until quit · transcribe the affected segment"

        for width: CGFloat in [1_080, 1_180] {
            let availableWidth = FullRoomHeaderStatusLayout.wideStatusWidth(
                for: width
            )
            let status = FullRoomHeaderStatusLayout.presentation(
                headerPresentation: .wide,
                windowWidth: width,
                statusMessage: longestStatus
            )

            XCTAssertEqual(status.style, .wideWrapped)
            XCTAssertEqual(status.visibleText, longestStatus)
            XCTAssertEqual(status.accessibilityValue, longestStatus)
            XCTAssertEqual(
                status.helpText,
                "System design · \(longestStatus)"
            )
            XCTAssertEqual(status.frameWidth, availableWidth)
            XCTAssertEqual(
                status.lineLimit,
                FullRoomHeaderStatusLayout.wrappedLineLimit
            )
            XCTAssertLessThanOrEqual(
                FullRoomHeaderStatusLayout.wrappedTextHeight(
                    of: longestStatus,
                    width: availableWidth
                ),
                FullRoomHeaderStatusLayout.maximumWrappedTextHeight
            )
        }

        let spacious = FullRoomHeaderStatusLayout.presentation(
            headerPresentation: .wide,
            windowWidth: 1_600,
            statusMessage: longestStatus
        )
        XCTAssertEqual(spacious.style, .wideInline)
        XCTAssertEqual(
            spacious.visibleText,
            "System design · \(longestStatus)"
        )

        let compact = FullRoomHeaderStatusLayout.presentation(
            headerPresentation: .compact,
            windowWidth: 1_080,
            statusMessage: longestStatus
        )
        XCTAssertEqual(compact.style, .compact)
        XCTAssertEqual(compact.visibleText, "System design")
        XCTAssertEqual(compact.accessibilityValue, longestStatus)
        XCTAssertEqual(
            compact.helpText,
            "System design · \(longestStatus)"
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
