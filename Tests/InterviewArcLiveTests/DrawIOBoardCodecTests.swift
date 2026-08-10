import Foundation
import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLive

final class DrawIOBoardCodecTests: XCTestCase {
    func testCanonicalSourceIsStableSafeAndRoundTripsEveryElement() throws {
        let api = BoardBox(
            id: BoardElementID("api"),
            frame: BoardRect(
                origin: BoardPoint(x: 80, y: 100),
                size: BoardSize(width: 180, height: 90)
            ),
            label: "API <gateway> & cache",
            kind: .service
        )
        let queue = BoardBox(
            id: BoardElementID("queue"),
            frame: BoardRect(
                origin: BoardPoint(x: 420, y: 220),
                size: BoardSize(width: 180, height: 90)
            ),
            label: "Durable queue",
            kind: .queue
        )
        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 1_200, height: 800)),
            elements: [
                .box(api),
                .box(queue),
                .connector(
                    BoardConnector(
                        id: BoardElementID("api-to-queue"),
                        start: BoardConnectorEndpoint(
                            point: BoardPoint(x: 260, y: 145),
                            elementID: api.id
                        ),
                        end: BoardConnectorEndpoint(
                            point: BoardPoint(x: 420, y: 265),
                            elementID: queue.id
                        ),
                        label: "events"
                    )
                ),
                .label(
                    BoardLabel(
                        id: BoardElementID("read-path"),
                        origin: BoardPoint(x: 80, y: 50),
                        text: "Read path"
                    )
                ),
                .stroke(
                    BoardStroke(
                        id: BoardElementID("latency-note"),
                        points: [
                            BoardPoint(x: 320, y: 240),
                            BoardPoint(x: 350, y: 270),
                            BoardPoint(x: 410, y: 260),
                        ],
                        width: 3
                    )
                ),
            ]
        )
        let codec = DrawIOBoardCodec()

        let first = try codec.encode(document)
        let second = try codec.encode(document)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("<mxfile"))
        XCTAssertTrue(first.contains("<mxGraphModel"))
        XCTAssertTrue(first.contains("API &lt;gateway&gt; &amp; cache"))
        XCTAssertTrue(first.contains("value=\"API &lt;gateway&gt; &amp; cache\""))
        XCTAssertTrue(first.contains("iaNodeKind=\"service\""))
        XCTAssertTrue(first.contains("iaNodeKind=\"queue\""))
        XCTAssertTrue(first.contains("iaNodeVisual=\"hexagon.fanout\""))
        XCTAssertTrue(first.contains("iaPictogram=\"fanout\""))
        XCTAssertTrue(first.contains("shape=hexagon;perimeter=hexagonPerimeter2"))
        XCTAssertTrue(first.contains("id=\"__ia_node_visual_0\""))
        XCTAssertTrue(first.contains("shape=image;imageAspect=0;aspect=fixed;pointerEvents=0"))
        XCTAssertTrue(first.contains("image=data:image/svg+xml,%3Csvg"))
        XCTAssertTrue(first.contains("selectable=\"0\""))
        XCTAssertTrue(first.contains("<Array as=\"points\">"))
        XCTAssertTrue(first.contains("<mxPoint x=\"340\" y=\"145\"/>"))
        XCTAssertTrue(first.contains("<mxPoint x=\"340\" y=\"265\"/>"))
        XCTAssertFalse(first.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(first.localizedCaseInsensitiveContains("href="))
        XCTAssertEqual(try codec.decode(first), document)
    }

    func testNodeVisualCellIDsAvoidCanonicalElementIDCollisions() throws {
        let box = BoardBox(
            id: BoardElementID("__ia_node_visual_0"),
            frame: BoardRect(
                origin: BoardPoint(x: 40, y: 40),
                size: BoardSize(width: 180, height: 90)
            ),
            label: "Collision-safe node",
            kind: .storage
        )
        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 640, height: 400)),
            elements: [.box(box)]
        )

        let source = try DrawIOBoardCodec().encode(document)

        XCTAssertTrue(source.contains("id=\"__ia_node_visual_0_\""))
        XCTAssertEqual(try DrawIOBoardCodec().decode(source), document)
    }

    func testCanonicalElementIDsZeroAndOneDoNotCollideWithDrawIORootCells() throws {
        let sourceBox = BoardBox(
            id: BoardElementID("0"),
            frame: BoardRect(
                origin: BoardPoint(x: 40, y: 40),
                size: BoardSize(width: 160, height: 90)
            ),
            label: "Source"
        )
        let targetBox = BoardBox(
            id: BoardElementID("1"),
            frame: BoardRect(
                origin: BoardPoint(x: 360, y: 160),
                size: BoardSize(width: 160, height: 90)
            ),
            label: "Target"
        )
        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 640, height: 400)),
            elements: [
                .box(sourceBox),
                .box(targetBox),
                .connector(
                    BoardConnector(
                        id: BoardElementID("route"),
                        start: BoardConnectorEndpoint(
                            point: BoardPoint(x: 200, y: 85),
                            elementID: sourceBox.id
                        ),
                        end: BoardConnectorEndpoint(
                            point: BoardPoint(x: 360, y: 205),
                            elementID: targetBox.id
                        )
                    )
                ),
            ]
        )

        let source = try DrawIOBoardCodec().encode(document)

        XCTAssertTrue(source.contains("id=\"__ia_element_0\""))
        XCTAssertTrue(source.contains("id=\"__ia_element_1\""))
        XCTAssertTrue(source.contains("source=\"__ia_element_0\" iaSourceElementID=\"0\""))
        XCTAssertTrue(source.contains("target=\"__ia_element_1\" iaTargetElementID=\"1\""))
        XCTAssertEqual(try DrawIOBoardCodec().decode(source), document)
    }

    func testDecodeRejectsOversizedOrActiveXMLWithoutPartialDocument() throws {
        let codec = DrawIOBoardCodec(maximumSourceBytes: 256)

        XCTAssertThrowsError(try codec.decode(String(repeating: "x", count: 257)))
        XCTAssertThrowsError(
            try codec.decode(
                """
                <?xml version="1.0"?>
                <!DOCTYPE mxfile [<!ENTITY remote SYSTEM "file:///tmp/private">]>
                <mxfile><diagram><mxGraphModel><root/></mxGraphModel></diagram></mxfile>
                """
            )
        )
        XCTAssertThrowsError(
            try codec.decode(
                "<mxfile><script>unsafe()</script></mxfile>"
            )
        )
    }

    func testEncodeRejectsTextThatIsNotLegalInXML() throws {
        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 640, height: 400)),
            elements: [
                .label(
                    BoardLabel(
                        id: BoardElementID("invalid-control"),
                        origin: BoardPoint(x: 40, y: 40),
                        text: "unsafe\u{0}text"
                    )
                ),
            ]
        )

        XCTAssertThrowsError(try DrawIOBoardCodec().encode(document))
    }

    func testEncodeEnforcesByteBudgetWhileAppending() throws {
        let codec = DrawIOBoardCodec(maximumSourceBytes: 128)

        XCTAssertThrowsError(try codec.encode(.empty)) { error in
            XCTAssertEqual(error as? DrawIOBoardCodecError, .sourceTooLarge)
        }
    }
}
