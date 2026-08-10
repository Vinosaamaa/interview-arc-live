import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLive

final class BoardEditorTests: XCTestCase {
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
