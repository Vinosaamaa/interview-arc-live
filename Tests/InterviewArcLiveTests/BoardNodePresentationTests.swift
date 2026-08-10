import CoreGraphics
import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLive

final class BoardNodePresentationTests: XCTestCase {
    func testBoardRailsAndControlsMatchApprovedDefaultLayoutContract() {
        XCTAssertEqual(BoardLayoutMetrics.revisionRailHeight, 54)
        XCTAssertEqual(BoardLayoutMetrics.toolRailHeight, 58)
        XCTAssertEqual(BoardLayoutMetrics.sectionLabelHeight, 44)
        XCTAssertEqual(BoardLayoutMetrics.minimumHitTarget, 44)
        XCTAssertEqual(BoardLayoutMetrics.toolControlHeight, 44)
        XCTAssertEqual(BoardLayoutMetrics.emptyStateMaximumWidth, 360)
    }

    func testCompactBoardRailsFitTheSupported680PointBoardWidth() {
        let boardWidth = BoardRailWidthBudget.supportedBoardWidth
        let worstCaseRevisionWidth = BoardRailWidthBudget
            .compactRevisionRequiredWidth(actionCount: 4)

        XCTAssertEqual(boardWidth, 680)
        XCTAssertGreaterThan(
            BoardRailWidthBudget.wideRevisionRequiredWidth,
            boardWidth
        )
        XCTAssertGreaterThan(
            BoardRailWidthBudget.wideToolbarRequiredWidth,
            boardWidth
        )
        XCTAssertEqual(worstCaseRevisionWidth, 428)
        XCTAssertEqual(BoardRailWidthBudget.compactToolbarRequiredWidth, 483)
        XCTAssertLessThanOrEqual(worstCaseRevisionWidth, boardWidth)
        XCTAssertLessThanOrEqual(
            BoardRailWidthBudget.compactToolbarRequiredWidth,
            boardWidth
        )
        XCTAssertGreaterThanOrEqual(
            BoardLayoutMetrics.minimumHitTarget,
            44
        )
        XCTAssertGreaterThanOrEqual(
            BoardRailWidthBudget.compactZoomWidth,
            BoardLayoutMetrics.minimumHitTarget
        )
    }

    func testCompactRevisionStatusPreservesEveryCanonicalLifecycleState() {
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus("Saving board…"),
            "Saving…"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus("Draft not saved"),
            "Draft unsaved"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus("Unsaved board"),
            "Unsaved"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(
                "Unsaved changes · revision 3"
            ),
            "Unsaved · r3"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(
                "Board saved · revision 4"
            ),
            "Saved · r4"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(
                "Return to the draft before editing."
            ),
            "Board issue"
        )
    }

    func testEveryCanonicalNodeKindHasOneDistinctVectorVocabulary() {
        let visuals = BoardNodeKind.selectableKinds.map(\.visual)

        XCTAssertEqual(Set(visuals.map(\.stableKey)).count, visuals.count)
        XCTAssertTrue(visuals.allSatisfy { !$0.accessibilityName.isEmpty })
        XCTAssertTrue(visuals.allSatisfy { !$0.drawIOShapeStyle.isEmpty })

        let rect = CGRect(x: 20, y: 30, width: 160, height: 90)
        for visual in visuals {
            XCTAssertFalse(visual.outlinePath(in: rect).commands.isEmpty)
            XCTAssertFalse(visual.pictogramPaths(in: rect).isEmpty)
            XCTAssertEqual(
                visual.outlinePath(in: rect).svgPathData,
                visual.outlinePath(in: rect).svgPathData
            )
        }
    }

    func testOrthogonalConnectorRouteUsesStableMidpointElbows() {
        XCTAssertEqual(
            BoardOrthogonalConnectorRoute(
                start: BoardPoint(x: 260, y: 145),
                end: BoardPoint(x: 520, y: 265)
            ).points,
            [
                BoardPoint(x: 260, y: 145),
                BoardPoint(x: 390, y: 145),
                BoardPoint(x: 390, y: 265),
                BoardPoint(x: 520, y: 265),
            ]
        )
        XCTAssertEqual(
            BoardOrthogonalConnectorRoute(
                start: BoardPoint(x: 10, y: 20),
                end: BoardPoint(x: 100, y: 20)
            ).points,
            [BoardPoint(x: 10, y: 20), BoardPoint(x: 100, y: 20)]
        )
    }
}
