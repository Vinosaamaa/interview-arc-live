import Foundation
import InterviewArcLiveCore
import XCTest

@testable import InterviewArcLive

final class ExcalidrawBoardCodecTests: XCTestCase {
    func testSceneRoundTripRetainsCanonicalBoardSemantics() throws {
        let service = BoardBox(
            id: BoardElementID("box-api"),
            frame: BoardRect(
                origin: BoardPoint(x: 120, y: 140),
                size: BoardSize(width: 180, height: 112)
            ),
            label: "API service",
            kind: .service,
            fill: .white,
            stroke: .nodeOutline
        )
        let queue = BoardBox(
            id: BoardElementID("box-queue"),
            frame: BoardRect(
                origin: BoardPoint(x: 480, y: 330),
                size: BoardSize(width: 180, height: 112)
            ),
            label: "Delivery queue",
            kind: .queue
        )
        let connector = BoardConnector(
            id: BoardElementID("connector-events"),
            start: BoardConnectorEndpoint(
                point: BoardPoint(x: 300, y: 196),
                elementID: service.id,
                anchorPolicy: .automatic
            ),
            end: BoardConnectorEndpoint(
                point: BoardPoint(x: 480, y: 386),
                elementID: queue.id,
                anchorPolicy: .preserved
            ),
            label: "events",
            stroke: .nodeOutline
        )
        let document = try BoardDocument(
            canvas: .init(size: .init(width: 1_200, height: 800)),
            elements: [.box(service), .box(queue), .connector(connector)]
        )
        let scene = ExcalidrawBoardScene(
            document: document,
            selectedElementID: queue.id,
            zoom: 1.25,
            readOnly: false,
            tool: .hand,
            boxKind: .queue,
            controls: ExcalidrawBoardControls(
                revisionStatus: "Unsaved changes · revision 2",
                notice: "Canvas element added and saved locally",
                noticeIsError: false,
                isInspecting: false,
                canSave: true,
                hasRevisions: true,
                canAttach: false,
                canExport: true,
                isExporting: false
            )
        )

        let first = try ExcalidrawBoardCodec.encodeScene(scene)
        let second = try ExcalidrawBoardCodec.encodeScene(scene)
        XCTAssertEqual(first, second)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(first.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(object["selectedID"] as? String, queue.id.rawValue)
        XCTAssertEqual(object["tool"] as? String, BoardEditorTool.hand.rawValue)
        let controls = try XCTUnwrap(object["controls"] as? [String: Any])
        XCTAssertEqual(controls["canSave"] as? Bool, true)
        XCTAssertEqual(
            controls["revisionStatus"] as? String,
            "Unsaved changes · revision 2"
        )
        XCTAssertEqual(
            controls["notice"] as? String,
            "Canvas element added and saved locally"
        )
        let encoded = try XCTUnwrap(object["elements"] as? [[String: Any]])
        XCTAssertEqual(encoded.count, 3)
        XCTAssertEqual(encoded.map { $0["type"] as? String }, [
            "connector", "box", "box",
        ])
        XCTAssertEqual(encoded[0]["sourceID"] as? String, service.id.rawValue)
        XCTAssertEqual(encoded[0]["targetID"] as? String, queue.id.rawValue)
        XCTAssertEqual(encoded[0]["startAnchorPolicy"] as? String, "automatic")
        XCTAssertEqual(encoded[0]["endAnchorPolicy"] as? String, "preserved")
        let route = try XCTUnwrap(encoded[0]["points"] as? [[String: Any]])
        XCTAssertEqual(route.count, 4)
        XCTAssertEqual(route[1]["x"] as? Double, 300)
        XCTAssertEqual(route[1]["y"] as? Double, 291)
        XCTAssertEqual(route[2]["x"] as? Double, 480)
        XCTAssertEqual(route[2]["y"] as? Double, 291)
        XCTAssertEqual(encoded[1]["nodeKind"] as? String, "service")
        XCTAssertEqual(encoded[2]["nodeKind"] as? String, "queue")
    }

    func testNewWebElementsReceiveStableBoardIDsBindingsAndWorldSpaceGeometry() throws {
        let change: [String: Any] = [
            "event": "scene",
            "unsupportedElementCount": 0,
            "zoom": 8.0,
            "tool": "hand",
            "boxKind": "generic",
            "selectedWebIDs": ["web-queue"],
            "elements": [
                box(
                    webID: "web-api",
                    x: -20,
                    y: 40,
                    label: "API",
                    kind: "service"
                ),
                box(
                    webID: "web-queue",
                    x: 1_160,
                    y: 760,
                    label: "Queue",
                    kind: "queue"
                ),
                [
                    "type": "connector",
                    "webID": "web-arrow",
                    "startX": 140.0,
                    "startY": 96.0,
                    "endX": 1_160.0,
                    "endY": 760.0,
                    "sourceWebID": "web-api",
                    "targetWebID": "web-queue",
                    "startAnchorPolicy": "automatic",
                    "endAnchorPolicy": "automatic",
                    "label": "events",
                    "stroke": "#4b3abf",
                ],
                [
                    "type": "label",
                    "webID": "web-label",
                    "x": 1_190.0,
                    "y": 790.0,
                    "text": "Delivery status",
                    "color": "#1f2937",
                ],
                [
                    "type": "stroke",
                    "webID": "web-stroke",
                    "points": [
                        ["x": -4.0, "y": 410.0],
                        ["x": 180.0, "y": 900.0],
                    ],
                    "width": 3.0,
                    "color": "#ed4e2f",
                ],
            ],
        ]

        let result = try ExcalidrawBoardCodec.decodeChange(
            from: change,
            currentDocument: .empty
        )
        XCTAssertTrue(result.requiresReload)
        XCTAssertEqual(result.zoom, BoardEditorState.maximumZoom)
        XCTAssertEqual(result.tool, .hand)
        XCTAssertEqual(result.boxKind, .generic)
        XCTAssertEqual(result.document.elements.map(\.id.rawValue), [
            "box-1",
            "box-2",
            "connector-1",
            "label-1",
            "stroke-1",
        ])
        XCTAssertEqual(result.selectedElementID, BoardElementID("box-2"))

        guard case .box(let first) = result.document.elements[0],
              case .box(let second) = result.document.elements[1],
              case .connector(let connector) = result.document.elements[2],
              case .label(let label) = result.document.elements[3],
              case .stroke(let stroke) = result.document.elements[4] else {
            return XCTFail("Expected the full supported Board element set")
        }
        XCTAssertEqual(first.frame.origin, BoardPoint(x: -20, y: 40))
        XCTAssertEqual(second.frame.origin, BoardPoint(x: 1_160, y: 760))
        XCTAssertEqual(connector.start.elementID, first.id)
        XCTAssertEqual(connector.end.elementID, second.id)
        XCTAssertEqual(connector.start.anchorPolicy, .automatic)
        XCTAssertEqual(label.origin, BoardPoint(x: 1_190, y: 790))
        XCTAssertEqual(stroke.points.first, BoardPoint(x: -4, y: 410))
        XCTAssertEqual(stroke.points.last, BoardPoint(x: 180, y: 900))
    }

    func testExcalidrawDiamondAndEllipseBecomeCanonicalNodeKinds() throws {
        let change: [String: Any] = [
            "event": "scene",
            "unsupportedElementCount": 0,
            "selectedWebIDs": [],
            "tool": "box",
            "boxKind": "ellipse",
            "elements": [
                box(
                    webID: "decision-web",
                    x: 80,
                    y: 80,
                    label: "Route?",
                    kind: "decision"
                ),
                box(
                    webID: "ellipse-web",
                    x: 360,
                    y: 80,
                    label: "Actor",
                    kind: "ellipse"
                ),
            ],
        ]

        let result = try ExcalidrawBoardCodec.decodeChange(
            from: change,
            currentDocument: .empty
        )
        let kinds: [BoardNodeKind] = result.document.elements.compactMap { element in
            guard case .box(let box) = element else { return nil }
            return box.kind
        }
        XCTAssertEqual(kinds, [.decision, .ellipse])
    }

    func testExistingIDsAreRetainedButPastedCanonicalIDsCannotTakeOwnership() throws {
        let original = BoardBox(
            id: BoardElementID("box-owned"),
            frame: BoardRect(
                origin: BoardPoint(x: 80, y: 80),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "Owned",
            kind: .service
        )
        let current = try BoardDocument(
            canvas: BoardDocument.empty.canvas,
            elements: [.box(original)]
        )
        let change: [String: Any] = [
            "event": "scene",
            "unsupportedElementCount": 0,
            "selectedWebIDs": [],
            "elements": [
                box(
                    webID: "box-owned",
                    boardID: "box-owned",
                    x: 100,
                    y: 120,
                    label: "Moved",
                    kind: "service"
                ),
                box(
                    webID: "pasted",
                    boardID: "fabricated-id",
                    x: 400,
                    y: 120,
                    label: "Pasted",
                    kind: "database"
                ),
            ],
        ]

        let result = try ExcalidrawBoardCodec.decodeChange(
            from: change,
            currentDocument: current
        )
        XCTAssertEqual(result.document.elements[0].id, original.id)
        XCTAssertEqual(result.document.elements[1].id, BoardElementID("box-1"))
        XCTAssertTrue(result.requiresReload)
    }

    func testUnsupportedElementIsRejectedBeforeCanonicalDecoding() {
        let change: [String: Any] = [
            "event": "scene",
            "unsupportedElementCount": 1,
            "selectedWebIDs": [],
            "elements": [],
        ]
        XCTAssertThrowsError(
            try ExcalidrawBoardCodec.decodeChange(
                from: change,
                currentDocument: .empty
            )
        ) { error in
            XCTAssertEqual(
                error as? ExcalidrawBoardCodecError,
                .unsupportedElements(count: 1)
            )
        }
    }

    func testDuplicateWebIdentityIsRejectedBeforeItCanRetargetConnectors() {
        let change: [String: Any] = [
            "event": "scene",
            "unsupportedElementCount": 0,
            "selectedWebIDs": [],
            "elements": [
                box(
                    webID: "duplicate",
                    x: 40,
                    y: 40,
                    label: "API",
                    kind: "service"
                ),
                box(
                    webID: "duplicate",
                    x: 300,
                    y: 40,
                    label: "Queue",
                    kind: "queue"
                ),
            ],
        ]
        XCTAssertThrowsError(
            try ExcalidrawBoardCodec.decodeChange(
                from: change,
                currentDocument: .empty
            )
        ) { error in
            XCTAssertEqual(
                error as? ExcalidrawBoardCodecError,
                .invalidElement
            )
        }
    }

    func testExistingWorldSpaceMoveDoesNotRequireVisibleReload() throws {
        let original = BoardBox(
            id: BoardElementID("box-owned"),
            frame: BoardRect(
                origin: BoardPoint(x: 80, y: 80),
                size: BoardSize(width: 160, height: 100)
            ),
            label: "Owned",
            kind: .service
        )
        let current = try BoardDocument(
            canvas: BoardDocument.empty.canvas,
            elements: [.box(original)]
        )
        let change: [String: Any] = [
            "event": "scene",
            "unsupportedElementCount": 0,
            "selectedWebIDs": ["box-owned"],
            "elements": [
                box(
                    webID: "box-owned",
                    boardID: "box-owned",
                    x: -140,
                    y: -220,
                    label: "Owned",
                    kind: "service"
                ),
            ],
        ]

        let result = try ExcalidrawBoardCodec.decodeChange(
            from: change,
            currentDocument: current
        )
        XCTAssertFalse(result.requiresReload)
        guard case .box(let moved) = result.document.elements.first else {
            return XCTFail("Expected moved existing box")
        }
        XCTAssertEqual(moved.id, original.id)
        XCTAssertEqual(moved.frame.origin, BoardPoint(x: -140, y: -220))
    }

    func testDocumentOnlyObservationDoesNotEchoStateIntoExcalidraw() {
        let controls = ExcalidrawBoardControls(
            revisionStatus: "Unsaved board",
            notice: nil,
            noticeIsError: false,
            isInspecting: false,
            canSave: true,
            hasRevisions: false,
            canAttach: false,
            canExport: false,
            isExporting: false
        )
        let state = ExcalidrawBoardState(
            selectedID: "box-1",
            zoom: 1,
            readOnly: false,
            tool: "select",
            boxKind: "generic",
            controls: controls
        )

        XCTAssertFalse(
            ExcalidrawBoardUpdatePolicy.requiresStateUpdate(
                previous: state,
                next: state
            )
        )
        XCTAssertTrue(
            ExcalidrawBoardUpdatePolicy.requiresStateUpdate(
                previous: state,
                next: ExcalidrawBoardState(
                    selectedID: "box-2",
                    zoom: 1,
                    readOnly: false,
                    tool: "select",
                    boxKind: "generic",
                    controls: controls
                )
            )
        )
    }

    func testOneShotCreationToolsReturnToNativeSelectAfterAcceptedCreation() {
        let box = BoardElement.box(
            BoardBox(
                id: BoardElementID("box-1"),
                frame: BoardRect(
                    origin: BoardPoint(x: 40, y: 40),
                    size: BoardSize(width: 160, height: 100)
                ),
                label: "API",
                kind: .service
            )
        )
        XCTAssertTrue(
            ExcalidrawBoardToolPolicy.returnsToSelect(
                afterAdding: [box],
                with: .box
            )
        )
        XCTAssertFalse(
            ExcalidrawBoardToolPolicy.returnsToSelect(
                afterAdding: [box],
                with: .pen
            )
        )
        XCTAssertFalse(
            ExcalidrawBoardToolPolicy.returnsToSelect(
                afterAdding: [],
                with: .box
            )
        )
    }

    @MainActor
    func testEmbeddedEditorSecurityRejectsRemoteAndFileNavigation() {
        XCTAssertEqual(
            ExcalidrawBoardStartupPolicy.readyTimeout,
            .seconds(8)
        )
        XCTAssertTrue(
            ExcalidrawBoardWebSecurity.permitsNavigation(
                to: URL(string: "interviewarc-board://editor/index.html")
            )
        )
        XCTAssertTrue(
            ExcalidrawBoardWebSecurity.permitsNavigation(
                to: URL(string: "about:blank")
            )
        )
        for value in [
            "https://example.com",
            "http://example.com",
            "file:///tmp/board.html",
            "data:text/html,unsafe",
        ] {
            XCTAssertFalse(
                ExcalidrawBoardWebSecurity.permitsNavigation(to: URL(string: value)),
                value
            )
        }
        XCTAssertTrue(
            ExcalidrawBoardWebSecurity.contentRuleJSON.contains("^https?://.*")
        )
        XCTAssertEqual(
            ExcalidrawBoardAssetHandler.mimeType(for: "woff2"),
            "font/woff2"
        )
        XCTAssertEqual(
            ExcalidrawBoardBridgePolicy.flushedCommandEvent,
            "flushedCommand"
        )
        XCTAssertFalse(
            ExcalidrawBoardBridgePolicy.permitsScene(
                afterNativeBaselineWasSent: false
            )
        )
        XCTAssertTrue(
            ExcalidrawBoardBridgePolicy.permitsScene(
                afterNativeBaselineWasSent: true
            )
        )
        XCTAssertFalse(
            ExcalidrawBoardBridgePolicy.permitsCommand(
                afterSceneAccepted: false
            )
        )
        XCTAssertTrue(
            ExcalidrawBoardBridgePolicy.permitsCommand(
                afterSceneAccepted: true
            )
        )
    }

    @MainActor
    func testRoomBridgeRetainsOneEditorCoordinatorAcrossSwiftUIReconstruction() {
        let bridge = ExcalidrawBoardBridgeController()
        let controls = ExcalidrawBoardControls(
            revisionStatus: "Unsaved board",
            notice: nil,
            noticeIsError: false,
            isInspecting: false,
            canSave: true,
            hasRevisions: false,
            canAttach: false,
            canExport: false,
            isExporting: false
        )
        let makeView = {
            ExcalidrawBoardEditorView(
                document: .empty,
                selectedElementID: nil,
                zoom: 1,
                tool: .select,
                boxKind: .generic,
                controls: controls,
                isReadOnly: false,
                bridgeController: bridge,
                onSceneChange: { _ in true },
                onCommand: { _ in },
                onReady: {},
                onIssue: { _ in },
                onFailure: { _ in }
            )
        }

        let first = makeView().makeCoordinator()
        let reconstructed = makeView().makeCoordinator()
        XCTAssertTrue(first === reconstructed)

        bridge.resetEditorSession()
        let retried = makeView().makeCoordinator()
        XCTAssertFalse(first === retried)
        bridge.resetEditorSession()
    }

    func testViewportPolicyRejectsTransientEmptyAndBackingScaleReparentSizes() {
        let current = NSSize(width: 820, height: 540)

        XCTAssertEqual(
            ExcalidrawBoardViewportPolicy.resolvedSize(
                current: current,
                proposed: .zero
            ),
            current
        )
        XCTAssertEqual(
            ExcalidrawBoardViewportPolicy.resolvedSize(
                current: current,
                proposed: NSSize(width: 1_640, height: 1_080),
                isSettlingReparent: true
            ),
            current
        )
        XCTAssertEqual(
            ExcalidrawBoardViewportPolicy.resolvedSize(
                current: current,
                proposed: NSSize(width: 1_640, height: 1_080)
            ),
            NSSize(width: 1_640, height: 1_080)
        )
        XCTAssertEqual(
            ExcalidrawBoardViewportPolicy.resolvedSize(
                current: current,
                proposed: NSSize(width: 640, height: 420)
            ),
            NSSize(width: 640, height: 420)
        )
        XCTAssertEqual(
            ExcalidrawBoardViewportPolicy.resolvedSize(
                current: .zero,
                proposed: .zero
            ),
            .zero
        )
    }

    private func box(
        webID: String,
        boardID: String? = nil,
        x: Double,
        y: Double,
        label: String,
        kind: String
    ) -> [String: Any] {
        var value: [String: Any] = [
            "type": "box",
            "webID": webID,
            "x": x,
            "y": y,
            "width": 96.0,
            "height": 64.0,
            "label": label,
            "nodeKind": kind,
            "fill": "#ffffff",
            "stroke": "#4b3abf",
        ]
        value["boardID"] = boardID
        return value
    }
}
