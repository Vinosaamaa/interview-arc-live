import CoreGraphics
import Foundation
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
            BoardRailPresentation.compactRevisionStatus(.saving),
            "Saving…"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(.draftNotSaved),
            "Draft unsaved"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(.unsaved),
            "Unsaved"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(
                .unsavedChanges(revision: 3)
            ),
            "Unsaved · r3"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(
                .saved(revision: 4)
            ),
            "Saved · r4"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(
                .viewing(revision: 2)
            ),
            "Viewing r2 · locked"
        )
        XCTAssertEqual(
            BoardRailPresentation.compactRevisionStatus(
                .error("Return to the draft before editing.")
            ),
            "Board issue"
        )
    }

    func testRevisionMenuBoundsRecentItemsAndFullBrowserKeepsEveryRevision() {
        let revisions = (0..<8).map { ordinal in
            BoardRevision(
                id: BoardRevisionID("revision-\(ordinal + 1)"),
                ordinal: ordinal,
                saveCommandID: CommandID("save-\(ordinal + 1)"),
                document: .empty
            )
        }

        XCTAssertEqual(BoardRevisionHistoryPresentation.recentLimit, 5)
        XCTAssertTrue(BoardRevisionHistoryPresentation.hasMore(revisions))
        XCTAssertEqual(
            BoardRevisionHistoryPresentation.recent(revisions).map(\.ordinal),
            [7, 6, 5, 4, 3]
        )
        XCTAssertEqual(
            BoardRevisionHistoryPresentation.all(revisions).map(\.ordinal),
            [7, 6, 5, 4, 3, 2, 1, 0]
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

    func testPictogramsScaleInsideTinyValidNodeFrames() {
        let tiny = CGRect(x: 7, y: 11, width: 20, height: 16)
        let tolerance = tiny.insetBy(dx: -0.001, dy: -0.001)

        for visual in BoardNodeKind.selectableKinds.map(\.visual) {
            for path in visual.pictogramPaths(in: tiny) {
                XCTAssertTrue(
                    tolerance.contains(path.cgPath.boundingBoxOfPath),
                    "\(visual.stableKey) exceeded the tiny node frame"
                )
            }
        }
    }

    func testDrawIOOverlayCarriesTheExactSharedOutlineDetailsAndPictogram() throws {
        let size = CGSize(width: 180, height: 90)
        let rect = CGRect(origin: .zero, size: size)

        for visual in BoardNodeKind.selectableKinds.map(\.visual) {
            let uri = DrawIONodeVisualOverlayEncoder.dataURI(
                visual: visual,
                canvasSize: size,
                fillHex: "f4f1ff",
                strokeHex: "1f2937"
            )
            let encoded = String(
                uri.dropFirst("data:image/svg+xml,".count)
            )
            let svg = try XCTUnwrap(encoded.removingPercentEncoding)

            XCTAssertTrue(
                svg.contains(
                    "data-board-node-visual='\(visual.stableKey)'"
                )
            )
            XCTAssertTrue(
                svg.contains(
                    "data-role='outline' d='\(visual.outlinePath(in: rect).svgPathData)'"
                )
            )
            XCTAssertTrue(
                svg.contains(
                    "data-role='fill' d='\(visual.outlinePath(in: rect).svgPathData)' fill='#f4f1ff'"
                )
            )
            for detail in visual.detailPaths(in: rect) {
                XCTAssertTrue(
                    svg.contains(
                        "data-role='detail' d='\(detail.svgPathData)'"
                    )
                )
            }
            for pictogram in visual.pictogramPaths(in: rect) {
                XCTAssertTrue(
                    svg.contains(
                        "data-role='pictogram' d='\(pictogram.svgPathData)'"
                    )
                )
            }
            XCTAssertEqual(
                svg.components(separatedBy: "data-role='fill'").count - 1,
                1
            )
            XCTAssertEqual(
                svg.components(separatedBy: "data-role='outline'").count - 1,
                1
            )
            XCTAssertEqual(
                svg.components(separatedBy: "data-role='detail'").count - 1,
                visual.detailPaths(in: rect).count
            )
            XCTAssertEqual(
                svg.components(separatedBy: "data-role='pictogram'").count - 1,
                visual.pictogramPaths(in: rect).count
            )
        }
    }

    func testConnectorAnchorsChooseNearestHorizontalAndVerticalSides() {
        let center = BoardBox(
            id: BoardElementID("center"),
            frame: BoardRect(
                origin: BoardPoint(x: 200, y: 200),
                size: BoardSize(width: 160, height: 90)
            ),
            label: "Center"
        )
        let left = BoardBox(
            id: BoardElementID("left"),
            frame: BoardRect(
                origin: BoardPoint(x: 0, y: 210),
                size: BoardSize(width: 120, height: 70)
            ),
            label: "Left"
        )
        let below = BoardBox(
            id: BoardElementID("below"),
            frame: BoardRect(
                origin: BoardPoint(x: 220, y: 400),
                size: BoardSize(width: 120, height: 70)
            ),
            label: "Below"
        )

        XCTAssertEqual(
            BoardConnectorAnchorLayout.between(source: center, target: left),
            BoardConnectorAnchorPair(
                start: BoardPoint(x: 200, y: 245),
                end: BoardPoint(x: 120, y: 245)
            )
        )
        XCTAssertEqual(
            BoardConnectorAnchorLayout.between(source: center, target: below),
            BoardConnectorAnchorPair(
                start: BoardPoint(x: 280, y: 290),
                end: BoardPoint(x: 280, y: 400)
            )
        )
    }

    func testSharedNodeLabelLayoutWrapsAndClipsDeterministically() {
        let rect = CGRect(x: 10, y: 49, width: 140, height: 34)
        let layout = BoardNodeLabelLayout(
            text: "Delivery status store",
            in: rect
        )

        XCTAssertEqual(layout.lines, ["Delivery status", "store"])
        XCTAssertEqual(layout.drawIOValue, "Delivery status\nstore")
        XCTAssertEqual(layout.lineRect(at: 0).height, 15)
        XCTAssertGreaterThanOrEqual(layout.lineRect(at: 0).minY, rect.minY)
        XCTAssertLessThanOrEqual(layout.lineRect(at: 1).maxY, rect.maxY)

        let clipped = BoardNodeLabelLayout(
            text: "one two three four five six seven eight nine",
            in: CGRect(x: 0, y: 0, width: 70, height: 30)
        )
        XCTAssertEqual(clipped.lines.count, 2)
        XCTAssertTrue(clipped.lines.last?.hasSuffix("…") == true)
    }

    func testSharedRenderOrderIsStableAcrossMixedCreationOrder() throws {
        let box = BoardElement.box(
            BoardBox(
                id: BoardElementID("box"),
                frame: BoardRect(
                    origin: BoardPoint(x: 20, y: 20),
                    size: BoardSize(width: 120, height: 70)
                ),
                label: "Box"
            )
        )
        let label = BoardElement.label(
            BoardLabel(
                id: BoardElementID("label"),
                origin: BoardPoint(x: 20, y: 120),
                text: "Label"
            )
        )
        let stroke = BoardElement.stroke(
            BoardStroke(
                id: BoardElementID("stroke"),
                points: [BoardPoint(x: 10, y: 10), BoardPoint(x: 30, y: 30)],
                width: 3
            )
        )
        let connector = BoardElement.connector(
            BoardConnector(
                id: BoardElementID("connector"),
                start: BoardConnectorEndpoint(point: BoardPoint(x: 10, y: 40)),
                end: BoardConnectorEndpoint(point: BoardPoint(x: 80, y: 40))
            )
        )
        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 400, height: 300)),
            elements: [box, label, connector, stroke]
        )

        XCTAssertEqual(
            BoardRenderOrder.elements(in: document).map(\.id),
            [connector.id, stroke.id, label.id, box.id]
        )
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
        XCTAssertEqual(
            BoardOrthogonalConnectorRoute(
                start: BoardPoint(x: 260, y: 400),
                end: BoardPoint(x: 180, y: 190)
            ).points,
            [
                BoardPoint(x: 260, y: 400),
                BoardPoint(x: 260, y: 295),
                BoardPoint(x: 180, y: 295),
                BoardPoint(x: 180, y: 190),
            ]
        )
    }
}
