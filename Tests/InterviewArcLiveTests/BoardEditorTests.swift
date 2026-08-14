import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLive

final class BoardEditorTests: XCTestCase {
    func testReplacingEmbeddedDocumentParticipatesInNativeUndoRedo() throws {
        var editor = BoardEditorState(document: .empty)
        let box = BoardBox(
            id: BoardElementID("box-1"),
            frame: BoardRect(
                origin: BoardPoint(x: 80, y: 90),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "API",
            kind: .service
        )
        let replacement = try BoardDocument(
            canvas: editor.document.canvas,
            elements: [.box(box)]
        )

        let changed = try editor.applyReportingMutation(
            .replaceDocument(
                replacement,
                selectedElementID: box.id
            )
        )
        XCTAssertTrue(changed.documentChanged)
        XCTAssertEqual(editor.document, replacement)
        XCTAssertEqual(editor.selectedElementID, box.id)

        try editor.apply(.undo)
        XCTAssertEqual(editor.document, .empty)
        XCTAssertNil(editor.selectedElementID)

        try editor.apply(.redo)
        XCTAssertEqual(editor.document, replacement)
        XCTAssertEqual(editor.selectedElementID, box.id)
    }

    func testConnectorKeyboardAndAccessibilityActivationShareSourceTargetFlow() {
        XCTAssertTrue(
            BoardAccessibilityActionPolicy.exposesDelete(isReadOnly: false)
        )
        XCTAssertFalse(
            BoardAccessibilityActionPolicy.exposesDelete(isReadOnly: true)
        )
        let source = BoardBox(
            id: BoardElementID("source"),
            frame: BoardRect(
                origin: BoardPoint(x: 20, y: 20),
                size: BoardSize(width: 160, height: 90)
            ),
            label: "API"
        )
        let target = BoardBox(
            id: BoardElementID("target"),
            frame: BoardRect(
                origin: BoardPoint(x: 260, y: 20),
                size: BoardSize(width: 160, height: 90)
            ),
            label: "Database"
        )

        for key in [
            BoardKeyboardActivationKey.returnKey,
            BoardKeyboardActivationKey.space,
        ] {
            XCTAssertEqual(
                BoardKeyboardActivation.resolve(
                    key: key,
                    tool: .connector,
                    selectedElement: .box(source)
                ),
                .activateConnectorBox(source.id)
            )
        }

        let chooseSource = BoardConnectorBoxActivation.resolve(
            sourceID: nil,
            activatedBoxID: source.id,
            tool: .connector
        )
        XCTAssertEqual(chooseSource, .chooseSource)
        XCTAssertEqual(
            chooseSource.accessibilityActionTitle,
            "Choose as connector source"
        )
        XCTAssertEqual(
            BoardConnectorBoxActivation.resolve(
                sourceID: source.id,
                activatedBoxID: target.id,
                tool: .connector
            ),
            .connect(sourceID: source.id, targetID: target.id)
        )
        let sameSource = BoardConnectorBoxActivation.resolve(
            sourceID: source.id,
            activatedBoxID: source.id,
            tool: .connector
        )
        XCTAssertEqual(sameSource, .chooseDifferentTarget)
        XCTAssertTrue(sameSource.accessibilityHint.contains("different target"))

        XCTAssertEqual(
            BoardKeyboardActivation.resolve(
                key: .returnKey,
                tool: .select,
                selectedElement: .box(source)
            ),
            .editLabel(source.id, source.label)
        )
        XCTAssertEqual(
            BoardKeyboardActivation.resolve(
                key: .space,
                tool: .select,
                selectedElement: .box(source)
            ),
            .ignored
        )
    }

    func testReducerMutationResultKeepsKeyboardFeedbackTruthful() throws {
        var editor = BoardEditorState(document: .empty)
        let unchanged = try editor.applyReportingMutation(.setTool(.box))
        XCTAssertFalse(unchanged.documentChanged)
        XCTAssertFalse(
            BoardKeyboardCreationOutcome.didCreateElement(
                documentChanged: unchanged.documentChanged,
                previousSelection: nil,
                currentSelection: nil
            )
        )

        let previousSelection = editor.selectedElementID
        let created = try editor.applyReportingMutation(
            .createBox(
                frame: BoardKeyboardPlacement.nextBoxFrame(in: editor.document),
                label: "Service",
                kind: .service
            )
        )
        XCTAssertTrue(created.documentChanged)
        XCTAssertTrue(
            BoardKeyboardCreationOutcome.didCreateElement(
                documentChanged: created.documentChanged,
                previousSelection: previousSelection,
                currentSelection: editor.selectedElementID
            )
        )

        let noMove = try editor.applyReportingMutation(
            .moveSelected(by: BoardPoint(x: 0, y: 0))
        )
        XCTAssertFalse(noMove.documentChanged)
    }

    func testEraserSamplingDropsNearbyDuplicatePointerUpdates() {
        let first = BoardPoint(x: 100, y: 100)

        XCTAssertTrue(
            BoardGestureSampling.shouldAcceptEraserPoint(first, after: nil)
        )
        XCTAssertFalse(
            BoardGestureSampling.shouldAcceptEraserPoint(
                BoardPoint(x: 103, y: 104),
                after: first
            )
        )
        XCTAssertTrue(
            BoardGestureSampling.shouldAcceptEraserPoint(
                BoardPoint(x: 106, y: 100),
                after: first
            )
        )
    }

    func testStraightLineSamplingKeepsOnlyTheGestureEndpoints() {
        let start = BoardPoint(x: 20, y: 30)

        XCTAssertEqual(
            BoardGestureSampling.straightLinePoints(from: nil, to: start),
            [start]
        )
        XCTAssertEqual(
            BoardGestureSampling.straightLinePoints(
                from: start,
                to: BoardPoint(x: 180, y: 140)
            ),
            [start, BoardPoint(x: 180, y: 140)]
        )
    }

    func testSelectToolStrokePointerContractMovesDeletesAndUndoesWithinCanvas() throws {
        XCTAssertGreaterThanOrEqual(
            BoardStrokePointerInteraction.minimumHitWidth,
            44
        )
        XCTAssertEqual(
            BoardStrokePointerInteraction.hitWidth(for: 3),
            BoardStrokePointerInteraction.minimumHitWidth
        )
        XCTAssertTrue(
            BoardStrokePointerInteraction.isEnabled(
                tool: .select,
                isReadOnly: false
            )
        )
        for tool in BoardEditorTool.allCases where tool != .select {
            XCTAssertFalse(
                BoardStrokePointerInteraction.isEnabled(
                    tool: tool,
                    isReadOnly: false
                ),
                "\(tool) must retain its own pointer gesture"
            )
        }
        XCTAssertFalse(
            BoardStrokePointerInteraction.isEnabled(
                tool: .select,
                isReadOnly: true
            )
        )

        let original = BoardStroke(
            id: BoardElementID("stroke"),
            points: [
                BoardPoint(x: 280, y: 210),
                BoardPoint(x: 295, y: 215),
            ],
            width: 3
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 300, height: 220)),
                elements: [.stroke(original)]
            )
        )

        try editor.apply(.select(original.id))
        try editor.apply(.moveSelected(by: BoardPoint(x: 30, y: 30)))
        let movedDocument = editor.document
        guard case .stroke(let moved) = movedDocument.elements.first else {
            return XCTFail("Expected moved stroke")
        }
        XCTAssertEqual(
            moved.points,
            [BoardPoint(x: 285, y: 215), BoardPoint(x: 300, y: 220)]
        )

        try editor.apply(.deleteSelection)
        XCTAssertTrue(editor.document.elements.isEmpty)
        XCTAssertNil(editor.selectedElementID)

        try editor.apply(.undo)
        XCTAssertEqual(editor.document, movedDocument)
        XCTAssertEqual(editor.selectedElementID, original.id)
        try editor.apply(.undo)
        XCTAssertEqual(editor.document.elements, [.stroke(original)])
        XCTAssertEqual(editor.selectedElementID, original.id)
    }

    func testBoxCreationPreservesEveryExplicitCanonicalNodeKind() throws {
        var editor = BoardEditorState(document: .empty)

        for (index, kind) in BoardNodeKind.selectableKinds.enumerated() {
            try editor.apply(
                .createBox(
                    frame: BoardRect(
                        origin: BoardPoint(x: Double(index * 170), y: 80),
                        size: BoardSize(width: 150, height: 80)
                    ),
                    label: kind.displayName,
                    kind: kind
                )
            )
        }

        let kinds: [BoardNodeKind] = editor.document.elements.compactMap { element in
            guard case .box(let box) = element else { return nil }
            return box.kind
        }
        XCTAssertEqual(kinds, BoardNodeKind.selectableKinds)
    }

    func testCreatingBoxAddsStableElementAndSupportsUndoRedo() throws {
        var editor = BoardEditorState(document: .empty)
        let frame = BoardRect(
            origin: BoardPoint(x: 120, y: 80),
            size: BoardSize(width: 180, height: 96)
        )

        try editor.apply(
            .createBox(frame: frame, label: "API gateway", kind: .service)
        )

        XCTAssertEqual(editor.document.elements.count, 1)
        guard case .box(let box) = editor.document.elements.first else {
            return XCTFail("Expected a box")
        }
        XCTAssertEqual(box.id, BoardElementID("box-1"))
        XCTAssertEqual(box.frame, frame)
        XCTAssertEqual(box.label, "API gateway")
        XCTAssertEqual(box.kind, .service)
        XCTAssertEqual(editor.selectedElementID, box.id)
        XCTAssertTrue(editor.canUndo)
        XCTAssertFalse(editor.canRedo)

        try editor.apply(.undo)
        XCTAssertTrue(editor.document.elements.isEmpty)
        XCTAssertTrue(editor.canRedo)

        try editor.apply(.redo)
        XCTAssertEqual(editor.document.elements, [.box(box)])
        XCTAssertEqual(editor.selectedElementID, box.id)
    }

    func testSelectionMovesAndDeletesABoxWithoutMutatingPriorHistory() throws {
        let originalFrame = BoardRect(
            origin: BoardPoint(x: 80, y: 100),
            size: BoardSize(width: 200, height: 110)
        )
        let box = BoardBox(
            id: BoardElementID("service"),
            frame: originalFrame,
            label: "Catalog service"
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 1_200, height: 800)),
                elements: [.box(box)]
            )
        )

        try editor.apply(.select(box.id))
        try editor.apply(.moveSelected(by: BoardPoint(x: 40, y: -20)))

        guard case .box(let moved) = editor.document.elements.first else {
            return XCTFail("Expected the moved box")
        }
        XCTAssertEqual(moved.frame.origin, BoardPoint(x: 120, y: 80))
        XCTAssertEqual(moved.frame.size, originalFrame.size)

        try editor.apply(.deleteSelection)
        XCTAssertTrue(editor.document.elements.isEmpty)
        XCTAssertNil(editor.selectedElementID)

        try editor.apply(.undo)
        XCTAssertEqual(editor.document.elements, [.box(moved)])
        XCTAssertEqual(editor.selectedElementID, box.id)
        try editor.apply(.undo)
        XCTAssertEqual(editor.document.elements, [.box(box)])
        XCTAssertEqual(editor.selectedElementID, box.id)
    }

    func testConnectingBoxesTracksTheirMovementAndCascadesOnDelete() throws {
        var editor = BoardEditorState(document: .empty)
        try editor.apply(
            .createBox(
                frame: BoardRect(
                    origin: BoardPoint(x: 80, y: 100),
                    size: BoardSize(width: 180, height: 90)
                ),
                label: "API",
                kind: .service
            )
        )
        let apiID = try XCTUnwrap(editor.selectedElementID)
        try editor.apply(
            .createBox(
                frame: BoardRect(
                    origin: BoardPoint(x: 420, y: 100),
                    size: BoardSize(width: 180, height: 90)
                ),
                label: "Queue",
                kind: .queue
            )
        )
        let queueID = try XCTUnwrap(editor.selectedElementID)

        try editor.apply(
            .connect(sourceBoxID: apiID, targetBoxID: queueID, label: "events")
        )
        let connectorID = try XCTUnwrap(editor.selectedElementID)
        try editor.apply(.updateLabel(id: connectorID, text: "durable events"))

        try editor.apply(.select(queueID))
        try editor.apply(.moveSelected(by: BoardPoint(x: 50, y: 30)))

        guard case .connector(let movedConnector) = editor.document.elements.last else {
            return XCTFail("Expected a connector")
        }
        XCTAssertEqual(movedConnector.id, BoardElementID("connector-1"))
        XCTAssertEqual(movedConnector.label, "durable events")
        XCTAssertEqual(movedConnector.start.elementID, apiID)
        XCTAssertEqual(movedConnector.end.elementID, queueID)
        XCTAssertEqual(movedConnector.end.point, BoardPoint(x: 470, y: 175))

        try editor.apply(.deleteSelection)
        XCTAssertFalse(editor.document.elements.contains { $0.boardID == queueID })
        XCTAssertFalse(editor.document.elements.contains { $0.boardID == connectorID })

        try editor.apply(.undo)
        XCTAssertTrue(editor.document.elements.contains { $0.boardID == queueID })
        XCTAssertTrue(editor.document.elements.contains { $0.boardID == connectorID })
    }

    func testAttachedConnectorReanchorsAcrossReversedMoveAndResize() throws {
        let target = BoardBox(
            id: BoardElementID("target"),
            frame: BoardRect(
                origin: BoardPoint(x: 100, y: 100),
                size: BoardSize(width: 160, height: 90)
            ),
            label: "Target"
        )
        let source = BoardBox(
            id: BoardElementID("source"),
            frame: BoardRect(
                origin: BoardPoint(x: 400, y: 100),
                size: BoardSize(width: 160, height: 90)
            ),
            label: "Source"
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 800, height: 700)),
                elements: [.box(target), .box(source)]
            )
        )

        try editor.apply(
            .connect(
                sourceBoxID: source.id,
                targetBoxID: target.id,
                label: "reversed"
            )
        )
        guard case .connector(let reversed) = editor.document.elements.last else {
            return XCTFail("Expected reversed connector")
        }
        XCTAssertEqual(reversed.start.point, BoardPoint(x: 400, y: 145))
        XCTAssertEqual(reversed.end.point, BoardPoint(x: 260, y: 145))
        XCTAssertEqual(reversed.start.anchorPolicy, .automatic)
        XCTAssertEqual(reversed.end.anchorPolicy, .automatic)
        XCTAssertEqual(
            BoardOrthogonalConnectorRoute(
                start: reversed.start.point,
                end: reversed.end.point
            ).points,
            [reversed.start.point, reversed.end.point]
        )

        try editor.apply(.select(source.id))
        try editor.apply(.moveSelected(by: BoardPoint(x: -220, y: 300)))
        guard case .connector(let vertical) = editor.document.elements.last else {
            return XCTFail("Expected vertical connector")
        }
        XCTAssertEqual(vertical.start.point, BoardPoint(x: 260, y: 400))
        XCTAssertEqual(vertical.end.point, BoardPoint(x: 180, y: 190))
        let movedDocument = editor.document

        try editor.apply(
            .resizeSelected(
                handle: .bottomTrailing,
                by: BoardPoint(x: 40, y: 20)
            )
        )
        guard case .connector(let resized) = editor.document.elements.last else {
            return XCTFail("Expected resized connector")
        }
        XCTAssertEqual(resized.start.point, BoardPoint(x: 280, y: 400))
        XCTAssertEqual(resized.end.point, BoardPoint(x: 180, y: 190))

        try editor.apply(.undo)
        XCTAssertEqual(editor.document, movedDocument)
        XCTAssertEqual(editor.selectedElementID, source.id)
    }

    func testResizePreservesImportedNormalizedConnectorSideOffsets() throws {
        let source = BoardBox(
            id: BoardElementID("source"),
            frame: BoardRect(
                origin: BoardPoint(x: 100, y: 100),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "Source"
        )
        let target = BoardBox(
            id: BoardElementID("target"),
            frame: BoardRect(
                origin: BoardPoint(x: 500, y: 100),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "Target"
        )
        let imported = BoardConnector(
            id: BoardElementID("custom"),
            start: BoardConnectorEndpoint(
                point: BoardPoint(x: 260, y: 125),
                elementID: source.id
            ),
            end: BoardConnectorEndpoint(
                point: BoardPoint(x: 500, y: 175),
                elementID: target.id
            )
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 900, height: 600)),
                elements: [.box(source), .box(target), .connector(imported)]
            )
        )

        try editor.apply(.select(source.id))
        try editor.apply(
            .resizeSelected(
                handle: .bottomTrailing,
                by: BoardPoint(x: 40, y: 100)
            )
        )

        guard case .connector(let resized) = editor.document.elements.last else {
            return XCTFail("Expected custom connector")
        }
        XCTAssertEqual(resized.start.point, BoardPoint(x: 300, y: 150))
        XCTAssertEqual(resized.end.point, BoardPoint(x: 500, y: 175))
        let resizedSource = try XCTUnwrap(
            editor.document.elements.compactMap { element -> BoardBox? in
                guard case .box(let box) = element,
                      box.id == source.id else {
                    return nil
                }
                return box
            }.first
        )
        XCTAssertEqual(
            BoardConnectorAnchorLayout.normalizedAnchor(
                for: resized.start.point,
                on: resizedSource
            ),
            BoardConnectorNormalizedAnchor(side: .right, offset: 0.25)
        )
    }

    func testResizePreservesImportedCenteredConnectorSides() throws {
        let source = BoardBox(
            id: BoardElementID("source"),
            frame: BoardRect(
                origin: BoardPoint(x: 100, y: 100),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "Source"
        )
        let target = BoardBox(
            id: BoardElementID("target"),
            frame: BoardRect(
                origin: BoardPoint(x: 500, y: 100),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "Target"
        )
        let imported = BoardConnector(
            id: BoardElementID("custom-centered"),
            start: BoardConnectorEndpoint(
                point: BoardPoint(x: 180, y: 100),
                elementID: source.id
            ),
            end: BoardConnectorEndpoint(
                point: BoardPoint(x: 580, y: 200),
                elementID: target.id
            )
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 900, height: 600)),
                elements: [.box(source), .box(target), .connector(imported)]
            )
        )

        try editor.apply(.select(source.id))
        try editor.apply(
            .resizeSelected(
                handle: .bottomTrailing,
                by: BoardPoint(x: 40, y: 100)
            )
        )

        guard case .connector(let resized) = editor.document.elements.last else {
            return XCTFail("Expected custom connector")
        }
        XCTAssertEqual(resized.start.point, BoardPoint(x: 200, y: 100))
        XCTAssertEqual(resized.end.point, BoardPoint(x: 580, y: 200))
    }

    func testImportedDefaultLookingAnchorsRemainPreservedAcrossAxisReversal() throws {
        let source = BoardBox(
            id: BoardElementID("source"),
            frame: BoardRect(
                origin: BoardPoint(x: 100, y: 100),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "Source"
        )
        let target = BoardBox(
            id: BoardElementID("target"),
            frame: BoardRect(
                origin: BoardPoint(x: 500, y: 100),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "Target"
        )
        let imported = BoardConnector(
            id: BoardElementID("imported-default-looking"),
            start: BoardConnectorEndpoint(
                point: BoardPoint(x: 260, y: 150),
                elementID: source.id
            ),
            end: BoardConnectorEndpoint(
                point: BoardPoint(x: 500, y: 150),
                elementID: target.id
            )
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 900, height: 600)),
                elements: [.box(source), .box(target), .connector(imported)]
            )
        )

        try editor.apply(.select(source.id))
        try editor.apply(.moveSelected(by: BoardPoint(x: 400, y: 250)))

        guard case .connector(let moved) = editor.document.elements.last else {
            return XCTFail("Expected preserved imported connector")
        }
        XCTAssertEqual(moved.start.point, BoardPoint(x: 660, y: 400))
        XCTAssertEqual(moved.end.point, BoardPoint(x: 500, y: 150))
        XCTAssertEqual(moved.start.anchorPolicy, .preserved)
        XCTAssertEqual(moved.end.anchorPolicy, .preserved)
    }

    func testMoveClampsBoxesLabelsAndStrokesAndKeepsAttachedConnectorAnchored() throws {
        let source = BoardBox(
            id: BoardElementID("source"),
            frame: BoardRect(
                origin: BoardPoint(x: 240, y: 40),
                size: BoardSize(width: 60, height: 60)
            ),
            label: "Source"
        )
        let target = BoardBox(
            id: BoardElementID("target"),
            frame: BoardRect(
                origin: BoardPoint(x: 40, y: 140),
                size: BoardSize(width: 80, height: 60)
            ),
            label: "Target"
        )
        let connector = BoardConnector(
            id: BoardElementID("attached"),
            start: BoardConnectorEndpoint(
                point: BoardPoint(x: 300, y: 70),
                elementID: source.id
            ),
            end: BoardConnectorEndpoint(
                point: BoardPoint(x: 40, y: 170),
                elementID: target.id
            )
        )
        let label = BoardLabel(
            id: BoardElementID("label"),
            origin: BoardPoint(x: 295, y: 210),
            text: "Edge"
        )
        let stroke = BoardStroke(
            id: BoardElementID("stroke"),
            points: [
                BoardPoint(x: 280, y: 210),
                BoardPoint(x: 295, y: 215),
            ],
            width: 3
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 300, height: 220)),
                elements: [
                    .box(source),
                    .box(target),
                    .connector(connector),
                    .label(label),
                    .stroke(stroke),
                ]
            )
        )

        try editor.apply(.select(source.id))
        try editor.apply(.moveSelected(by: BoardPoint(x: 10, y: 0)))
        XCTAssertEqual(editor.document.elements[0], .box(source))
        XCTAssertEqual(editor.document.elements[2], .connector(connector))

        try editor.apply(.moveSelected(by: BoardPoint(x: -20, y: 0)))
        guard case .box(let movedSource) = editor.document.elements[0],
              case .connector(let reanchored) = editor.document.elements[2] else {
            return XCTFail("Expected moved source and attached connector")
        }
        XCTAssertEqual(movedSource.frame.origin, BoardPoint(x: 220, y: 40))
        XCTAssertEqual(reanchored.start.point, BoardPoint(x: 280, y: 70))
        XCTAssertEqual(reanchored.start.elementID, source.id)

        try editor.apply(.select(label.id))
        try editor.apply(.moveSelected(by: BoardPoint(x: 10, y: 10)))
        guard case .label(let clampedLabel) = editor.document.elements[3] else {
            return XCTFail("Expected label")
        }
        XCTAssertEqual(clampedLabel.origin, BoardPoint(x: 60, y: 188))

        try editor.apply(.select(stroke.id))
        try editor.apply(.moveSelected(by: BoardPoint(x: 20, y: 20)))
        guard case .stroke(let clampedStroke) = editor.document.elements[4] else {
            return XCTFail("Expected stroke")
        }
        XCTAssertEqual(
            clampedStroke.points,
            [
                BoardPoint(x: 285, y: 215),
                BoardPoint(x: 300, y: 220),
            ]
        )

        let beforeConnectorNudge = editor.document
        try editor.apply(.select(connector.id))
        try editor.apply(.moveSelected(by: BoardPoint(x: 10, y: 10)))
        XCTAssertEqual(editor.document, beforeConnectorNudge)
    }

    func testSelectionCapabilitiesOnlyResizeBoxesAndKeepAttachedRoutesFixed() {
        let box = BoardBox(
            id: BoardElementID("box"),
            frame: BoardRect(
                origin: BoardPoint(x: 20, y: 20),
                size: BoardSize(width: 120, height: 80)
            ),
            label: "Box"
        )
        let attached = BoardConnector(
            id: BoardElementID("attached"),
            start: BoardConnectorEndpoint(
                point: BoardPoint(x: 140, y: 60),
                elementID: box.id
            ),
            end: BoardConnectorEndpoint(point: BoardPoint(x: 240, y: 60))
        )
        let free = BoardConnector(
            id: BoardElementID("free"),
            start: BoardConnectorEndpoint(point: BoardPoint(x: 20, y: 160)),
            end: BoardConnectorEndpoint(point: BoardPoint(x: 240, y: 160))
        )
        let label = BoardLabel(
            id: BoardElementID("label"),
            origin: BoardPoint(x: 20, y: 200),
            text: "Label"
        )
        let stroke = BoardStroke(
            id: BoardElementID("stroke"),
            points: [BoardPoint(x: 20, y: 240)],
            width: 3
        )

        let boxCapabilities = BoardSelectionCapabilities(element: .box(box))
        XCTAssertTrue(boxCapabilities.canMove)
        XCTAssertTrue(boxCapabilities.canResize)
        XCTAssertTrue(boxCapabilities.canEditLabel)
        XCTAssertFalse(
            BoardSelectionCapabilities(element: .connector(attached)).canMove
        )
        XCTAssertTrue(
            BoardSelectionCapabilities(element: .connector(free)).canMove
        )
        XCTAssertFalse(
            BoardSelectionCapabilities(element: .connector(free)).canResize
        )
        XCTAssertFalse(
            BoardSelectionCapabilities(element: .label(label)).canResize
        )
        XCTAssertFalse(
            BoardSelectionCapabilities(element: .stroke(stroke)).canResize
        )
        XCTAssertFalse(
            BoardSelectionCapabilities(element: .stroke(stroke)).canEditLabel
        )
    }

    func testSelectedBoxResizePersistsGeometryAndReanchorsConnector() throws {
        var editor = BoardEditorState(document: .empty)
        try editor.apply(
            .createBox(
                frame: BoardRect(
                    origin: BoardPoint(x: 80, y: 100),
                    size: BoardSize(width: 180, height: 90)
                ),
                label: "API",
                kind: .service
            )
        )
        let apiID = try XCTUnwrap(editor.selectedElementID)
        try editor.apply(
            .createBox(
                frame: BoardRect(
                    origin: BoardPoint(x: 520, y: 220),
                    size: BoardSize(width: 180, height: 90)
                ),
                label: "Queue",
                kind: .queue
            )
        )
        let queueID = try XCTUnwrap(editor.selectedElementID)
        try editor.apply(
            .connect(sourceBoxID: apiID, targetBoxID: queueID, label: "events")
        )

        try editor.apply(.select(apiID))
        try editor.apply(
            .resizeSelected(
                handle: .bottomTrailing,
                by: BoardPoint(x: 40, y: 20)
            )
        )

        guard case .box(let resized) = editor.document.elements[0],
              case .connector(let connector) = editor.document.elements[2] else {
            return XCTFail("Expected resized box and connector")
        }
        XCTAssertEqual(resized.frame.origin, BoardPoint(x: 80, y: 100))
        XCTAssertEqual(resized.frame.size, BoardSize(width: 220, height: 110))
        XCTAssertEqual(connector.start.point, BoardPoint(x: 300, y: 155))
        XCTAssertEqual(connector.end.point, BoardPoint(x: 520, y: 265))

        try editor.apply(.undo)
        guard case .box(let restored) = editor.document.elements[0],
              case .connector(let restoredConnector) = editor.document.elements[2] else {
            return XCTFail("Expected restored box and connector")
        }
        XCTAssertEqual(restored.frame.size, BoardSize(width: 180, height: 90))
        XCTAssertEqual(restoredConnector.start.point, BoardPoint(x: 260, y: 145))
    }

    func testResizeClampsToMinimumSizeAndCanvasBounds() throws {
        let box = BoardBox(
            id: BoardElementID("bounded"),
            frame: BoardRect(
                origin: BoardPoint(x: 40, y: 50),
                size: BoardSize(width: 120, height: 80)
            ),
            label: "Bounded"
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 300, height: 220)),
                elements: [.box(box)]
            )
        )
        try editor.apply(.select(box.id))
        try editor.apply(
            .resizeSelected(
                handle: .topLeading,
                by: BoardPoint(x: 500, y: 500)
            )
        )
        guard case .box(let minimum) = editor.document.elements[0] else {
            return XCTFail("Expected box")
        }
        XCTAssertEqual(
            minimum.frame,
            BoardRect(
                origin: BoardPoint(x: 64, y: 66),
                size: BoardSize(width: 96, height: 64)
            )
        )

        try editor.apply(
            .resizeSelected(
                handle: .bottomTrailing,
                by: BoardPoint(x: 500, y: 500)
            )
        )
        guard case .box(let maximum) = editor.document.elements[0] else {
            return XCTFail("Expected box")
        }
        XCTAssertEqual(maximum.frame.size, BoardSize(width: 236, height: 154))
    }

    func testResizeNormalizesAnExistingOutOfBoundsBoxBeforeApplyingDelta() throws {
        let box = BoardBox(
            id: BoardElementID("outside"),
            frame: BoardRect(
                origin: BoardPoint(x: 280, y: 210),
                size: BoardSize(width: 120, height: 80)
            ),
            label: "Outside"
        )
        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 300, height: 220)),
                elements: [.box(box)]
            )
        )
        try editor.apply(.select(box.id))

        try editor.apply(
            .resizeSelected(
                handle: .bottomTrailing,
                by: BoardPoint(x: 40, y: 40)
            )
        )

        guard case .box(let normalized) = editor.document.elements[0] else {
            return XCTFail("Expected box")
        }
        XCTAssertEqual(
            normalized.frame,
            BoardRect(
                origin: BoardPoint(x: 180, y: 140),
                size: BoardSize(width: 120, height: 80)
            )
        )
    }

    func testKeyboardTraversalWrapsInCanonicalDocumentOrder() throws {
        var editor = BoardEditorState(document: .empty)
        try editor.apply(
            .createLabel(origin: BoardPoint(x: 20, y: 20), text: "First")
        )
        try editor.apply(
            .createLabel(origin: BoardPoint(x: 40, y: 40), text: "Second")
        )
        try editor.apply(.select(nil))

        try editor.apply(.selectNext)
        XCTAssertEqual(editor.selectedElementID, BoardElementID("label-1"))
        try editor.apply(.selectNext)
        XCTAssertEqual(editor.selectedElementID, BoardElementID("label-2"))
        try editor.apply(.selectNext)
        XCTAssertEqual(editor.selectedElementID, BoardElementID("label-1"))
        try editor.apply(.selectPrevious)
        XCTAssertEqual(editor.selectedElementID, BoardElementID("label-2"))
    }

    func testKeyboardPlacementIsDeterministicAndInsideCanvas() throws {
        var document = BoardDocument.empty
        let first = BoardKeyboardPlacement.nextBoxFrame(in: document)
        XCTAssertEqual(first.origin, BoardPoint(x: 40, y: 40))
        XCTAssertEqual(first.size, BoardSize(width: 120, height: 112))

        document = try BoardDocument(
            canvas: document.canvas,
            elements: [
                .box(
                    BoardBox(
                        id: BoardElementID("first"),
                        frame: first,
                        label: "First"
                    )
                ),
            ]
        )
        let second = BoardKeyboardPlacement.nextBoxFrame(in: document)
        XCTAssertEqual(second.origin, BoardPoint(x: 184, y: 40))
        XCTAssertLessThanOrEqual(
            second.origin.x + second.size.width,
            document.canvas.size.width
        )
    }

    func testPointerPlacementCentersNearSquareDefaultNodeAndClampsItsExtent() {
        let canvas = BoardSize(width: 300, height: 220)

        XCTAssertEqual(
            BoardNodeCreationDefaults.frame(
                centeredAt: BoardPoint(x: 150, y: 110),
                in: canvas
            ),
            BoardRect(
                origin: BoardPoint(x: 90, y: 54),
                size: BoardSize(width: 120, height: 112)
            )
        )
        XCTAssertEqual(
            BoardNodeCreationDefaults.frame(
                centeredAt: BoardPoint(x: 298, y: 218),
                in: canvas
            ),
            BoardRect(
                origin: BoardPoint(x: 180, y: 108),
                size: BoardSize(width: 120, height: 112)
            )
        )
    }

    func testPointerLabelCreationClampsTheEntireCanonicalExtentToCanvas() throws {
        let canvas = BoardSize(width: 300, height: 220)
        let requested = BoardPoint(x: 295, y: 210)
        let expected = BoardPoint(x: 60, y: 188)
        XCTAssertEqual(
            BoardElementLayout.clampedLabelOrigin(requested, in: canvas),
            expected
        )

        var editor = BoardEditorState(
            document: try BoardDocument(
                canvas: BoardCanvas(size: canvas),
                elements: []
            )
        )
        try editor.apply(.createLabel(origin: requested, text: "Edge label"))

        guard case .label(let label) = editor.document.elements.first else {
            return XCTFail("Expected label")
        }
        XCTAssertEqual(label.origin, expected)
        XCTAssertLessThanOrEqual(
            label.origin.x + BoardElementLayout.labelSize.width,
            canvas.width
        )
        XCTAssertLessThanOrEqual(
            label.origin.y + BoardElementLayout.labelSize.height,
            canvas.height
        )
        try editor.apply(.undo)
        XCTAssertTrue(editor.document.elements.isEmpty)
    }

    func testLabelsPenEraserAndZoomRemainUndoableAndBounded() throws {
        var editor = BoardEditorState(document: .empty)
        try editor.apply(
            .createLabel(
                origin: BoardPoint(x: 100, y: 70),
                text: "Read path"
            )
        )
        XCTAssertEqual(editor.selectedElementID, BoardElementID("label-1"))

        let points = [
            BoardPoint(x: 100, y: 180),
            BoardPoint(x: 130, y: 210),
            BoardPoint(x: 190, y: 205),
        ]
        try editor.apply(.addStroke(points: points))
        XCTAssertEqual(editor.selectedElementID, BoardElementID("stroke-1"))
        guard case .stroke(let stroke) = editor.document.elements.last else {
            return XCTFail("Expected a freehand stroke")
        }
        XCTAssertEqual(stroke.color, BoardColor(hexRGB: "ed4e2f"))

        try editor.apply(.eraseStroke(at: BoardPoint(x: 145, y: 208), radius: 12))
        XCTAssertFalse(
            editor.document.elements.contains {
                $0.boardID == BoardElementID("stroke-1")
            }
        )
        try editor.apply(.undo)
        XCTAssertTrue(
            editor.document.elements.contains {
                $0.boardID == BoardElementID("stroke-1")
            }
        )

        try editor.apply(.setTool(.pen))
        try editor.apply(.setZoom(99))
        XCTAssertEqual(editor.tool, .pen)
        XCTAssertEqual(editor.zoom, BoardEditorState.maximumZoom)
        try editor.apply(.resetZoom)
        XCTAssertEqual(editor.zoom, 1)
    }
}
