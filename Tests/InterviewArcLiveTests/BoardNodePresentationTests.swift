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
        XCTAssertEqual(BoardCanvasVisualMetrics.gridSpacing, 20)
        XCTAssertEqual(BoardCanvasVisualMetrics.gridDotDiameter, 1.6)
        XCTAssertEqual(BoardCanvasVisualMetrics.gridDotOpacity, 0.22)
        XCTAssertEqual(BoardCanvasVisualMetrics.footerMaximumWidth, 420)
        XCTAssertEqual(BoardRailInteractionMetrics.cornerRadius, 9)
        XCTAssertEqual(BoardRailInteractionMetrics.pressedScale, 0.985)
        XCTAssertEqual(BoardRailInteractionMetrics.disabledOpacity, 0.5)
        XCTAssertEqual(BoardRailInteractionMetrics.transitionDuration, 0.12)
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

    func testWideRailsConsumeTheRenderedWidthAndCompactRailsStayBounded() {
        let wideWidth: CGFloat = 960
        let wideRevision = BoardRailWidthBudget.revisionResolution(
            availableWidth: wideWidth,
            actionCount: 4
        )
        let wideToolbar = BoardRailWidthBudget.toolbarResolution(
            availableWidth: wideWidth
        )

        XCTAssertEqual(wideRevision.variant, .wide)
        XCTAssertEqual(wideRevision.renderedWidth, wideWidth)
        XCTAssertEqual(wideToolbar.variant, .wide)
        XCTAssertEqual(wideToolbar.renderedWidth, wideWidth)
        XCTAssertGreaterThanOrEqual(
            BoardRailWidthBudget.wideRevisionGroupGapMinimum,
            24
        )
        XCTAssertGreaterThanOrEqual(
            BoardRailWidthBudget.wideToolbarGroupGapMinimum,
            12
        )

        let compactRevision = BoardRailWidthBudget.revisionResolution(
            availableWidth: BoardRailWidthBudget.supportedBoardWidth,
            actionCount: 4
        )
        let compactToolbar = BoardRailWidthBudget.toolbarResolution(
            availableWidth: BoardRailWidthBudget.supportedBoardWidth
        )

        XCTAssertEqual(compactRevision.variant, .compact)
        XCTAssertEqual(compactRevision.renderedWidth, 428)
        XCTAssertLessThanOrEqual(
            compactRevision.renderedWidth,
            BoardRailWidthBudget.supportedBoardWidth
        )
        XCTAssertEqual(compactToolbar.variant, .compact)
        XCTAssertEqual(compactToolbar.renderedWidth, 483)
        XCTAssertLessThanOrEqual(
            compactToolbar.renderedWidth,
            BoardRailWidthBudget.supportedBoardWidth
        )
    }

    func testDefaultNodeStyleUsesNearSquareBrandGeometryWithoutOverridingAuthoredStyle() throws {
        XCTAssertEqual(
            BoardNodeCreationDefaults.defaultSize,
            BoardSize(width: 120, height: 112)
        )
        XCTAssertLessThanOrEqual(
            BoardNodeCreationDefaults.defaultSize.width
                / BoardNodeCreationDefaults.defaultSize.height,
            1.1
        )

        let created = BoardBox(
            id: BoardElementID("created"),
            frame: BoardRect(
                origin: BoardPoint(x: 40, y: 40),
                size: BoardNodeCreationDefaults.defaultSize
            ),
            label: "Fanout workers",
            kind: .service
        )
        XCTAssertEqual(created.fill, .white)
        XCTAssertEqual(created.stroke, .nodeOutline)
        XCTAssertEqual(created.stroke.hexRGB, "4b3abf")

        let authored = BoardBox(
            id: BoardElementID("authored"),
            frame: created.frame,
            label: "Imported service",
            kind: .service,
            fill: BoardColor(hexRGB: "f8fafc"),
            stroke: BoardColor(hexRGB: "1f2937")
        )
        let decoded = try JSONDecoder().decode(
            BoardBox.self,
            from: JSONEncoder().encode(authored)
        )
        XCTAssertEqual(decoded.fill.hexRGB, "f8fafc")
        XCTAssertEqual(decoded.stroke.hexRGB, "1f2937")
    }

    func testFooterKeepsCanvasFeedbackDistinctFromRevisionStatus() {
        let error = "Return to the draft before editing."
        let feedback = "Service node added and selected"
        let export = "Editable source · SVG + PNG available"
        let cases: [(
            error: String?,
            export: String?,
            feedback: String?,
            expected: BoardFooterPresentation
        )] = [
            (nil, nil, nil, BoardFooterPresentation(
                text: "Editable source autosaves locally",
                systemImage: "internaldrive",
                tone: .neutral
            )),
            (nil, export, nil, BoardFooterPresentation(
                text: export,
                systemImage: "checkmark.circle",
                tone: .confirmation
            )),
            (nil, nil, feedback, BoardFooterPresentation(
                text: feedback,
                systemImage: "info.circle",
                tone: .feedback
            )),
            (nil, export, feedback, BoardFooterPresentation(
                text: feedback,
                systemImage: "info.circle",
                tone: .feedback
            )),
            (error, nil, nil, BoardFooterPresentation(
                text: error,
                systemImage: "exclamationmark.triangle",
                tone: .error
            )),
            (error, export, nil, BoardFooterPresentation(
                text: error,
                systemImage: "exclamationmark.triangle",
                tone: .error
            )),
            (error, nil, feedback, BoardFooterPresentation(
                text: error,
                systemImage: "exclamationmark.triangle",
                tone: .error
            )),
            (error, export, feedback, BoardFooterPresentation(
                text: error,
                systemImage: "exclamationmark.triangle",
                tone: .error
            )),
        ]

        for value in cases {
            XCTAssertEqual(
                BoardFooterPresentation.make(
                    errorMessage: value.error,
                    exportMessage: value.export,
                    interactionFeedback: value.feedback
                ),
                value.expected
            )
        }
        XCTAssertFalse(feedback.localizedCaseInsensitiveContains("unsaved"))
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
            XCTAssertEqual(visual.strokeWidth(in: rect), 1.5)
            XCTAssertEqual(
                visual.strokeWidth(in: rect, isSelected: true),
                2
            )
        }
    }

    func testEveryVisualPathStaysFiniteAndInsideEveryValidNodeFrame() {
        let frames = [
            CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 3, y: 5, width: 10, height: 8),
            CGRect(x: 7, y: 11, width: 20, height: 16),
            CGRect(x: 20, y: 30, width: 160, height: 90),
        ]

        for frame in frames {
            let tolerance = frame.insetBy(dx: -0.000_001, dy: -0.000_001)
            for visual in BoardNodeKind.selectableKinds.map(\.visual) {
                let labelBounds = visual.labelRect(in: frame)
                XCTAssertTrue(
                    [
                        labelBounds.minX,
                        labelBounds.minY,
                        labelBounds.maxX,
                        labelBounds.maxY,
                    ].allSatisfy(\.isFinite),
                    "\(visual.stableKey) produced a non-finite label rect"
                )
                XCTAssertTrue(
                    tolerance.contains(labelBounds),
                    "\(visual.stableKey) label exceeded \(frame): \(labelBounds)"
                )
                let labelLayout = BoardNodeLabelLayout(
                    text: "Delivery status store",
                    in: labelBounds
                )
                for index in labelLayout.lines.indices {
                    let lineBounds = labelLayout.lineRect(at: index)
                    XCTAssertTrue(
                        [
                            lineBounds.minX,
                            lineBounds.minY,
                            lineBounds.maxX,
                            lineBounds.maxY,
                        ].allSatisfy(\.isFinite),
                        "\(visual.stableKey) produced a non-finite line rect"
                    )
                    XCTAssertTrue(
                        tolerance.contains(lineBounds),
                        "\(visual.stableKey) line exceeded \(frame): \(lineBounds)"
                    )
                    XCTAssertTrue(
                        labelBounds.insetBy(
                            dx: -0.000_001,
                            dy: -0.000_001
                        ).contains(lineBounds),
                        "\(visual.stableKey) line exceeded its label rect"
                    )
                }
                let strokeWidth = visual.strokeWidth(in: frame)
                XCTAssertTrue(strokeWidth.isFinite)
                XCTAssertGreaterThan(strokeWidth, 0)
                let paths = [visual.outlinePath(in: frame)]
                    + visual.detailPaths(in: frame)
                    + visual.pictogramPaths(in: frame)
                for path in paths {
                    let bounds = path.cgPath.boundingBoxOfPath
                    let paintedBounds = path.cgPath.copy(
                        strokingWithWidth: strokeWidth,
                        lineCap: .round,
                        lineJoin: .round,
                        miterLimit: 10
                    ).boundingBoxOfPath
                    XCTAssertTrue(
                        [
                            bounds.minX,
                            bounds.minY,
                            bounds.maxX,
                            bounds.maxY,
                        ].allSatisfy(\.isFinite),
                        "\(visual.stableKey) produced non-finite bounds in \(frame)"
                    )
                    XCTAssertTrue(
                        tolerance.contains(bounds),
                        "\(visual.stableKey) exceeded \(frame): \(bounds)"
                    )
                    XCTAssertTrue(
                        tolerance.contains(paintedBounds),
                        "\(visual.stableKey) paint exceeded \(frame): \(paintedBounds)"
                    )
                }
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

    func testDrawIOOverlayUsesTheSharedGeometryAwareStrokeWidth() throws {
        let sizes = [
            CGSize(width: 0.1, height: 0.1),
            CGSize(width: 1, height: 1),
            CGSize(width: 10, height: 8),
            CGSize(width: 20, height: 16),
            CGSize(width: 160, height: 90),
        ]

        for size in sizes {
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
                        "stroke-width='\(BoardVectorPath.number(visual.strokeWidth(in: rect)))'"
                    )
                )
            }
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
        XCTAssertEqual(layout.resolvedLineHeight, 15)
        XCTAssertEqual(layout.resolvedFontSize, 13)
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
