import CoreGraphics
import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLive

final class BoardNodePresentationTests: XCTestCase {
    func testBoardRailsAndControlsMatchApprovedDefaultLayoutContract() {
        XCTAssertEqual(BoardLayoutMetrics.revisionRailHeight, 54)
        XCTAssertEqual(BoardLayoutMetrics.toolRailHeight, 58)
        XCTAssertEqual(BoardLayoutMetrics.sectionLabelHeight, 44)
        XCTAssertEqual(BoardLayoutMetrics.toolControlHeight, 38)
        XCTAssertEqual(BoardLayoutMetrics.emptyStateMaximumWidth, 360)
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
