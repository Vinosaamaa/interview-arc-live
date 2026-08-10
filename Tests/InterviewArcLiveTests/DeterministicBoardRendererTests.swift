import Foundation
import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLive

final class DeterministicBoardRendererTests: XCTestCase {
    func testIdenticalDocumentAndSettingsProduceIdenticalSafeArtifactBytes() throws {
        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 640, height: 400)),
            elements: [
                .box(
                    BoardBox(
                        id: BoardElementID("gateway"),
                        frame: BoardRect(
                            origin: BoardPoint(x: 80, y: 90),
                            size: BoardSize(width: 180, height: 90)
                        ),
                        label: "Gateway <script>alert(1)</script>",
                        kind: .service
                    )
                ),
                .label(
                    BoardLabel(
                        id: BoardElementID("title"),
                        origin: BoardPoint(x: 80, y: 45),
                        text: "Public test diagram"
                    )
                ),
                .stroke(
                    BoardStroke(
                        id: BoardElementID("note"),
                        points: [
                            BoardPoint(x: 300, y: 210),
                            BoardPoint(x: 350, y: 240),
                            BoardPoint(x: 410, y: 220),
                        ],
                        width: 3
                    )
                ),
            ]
        )
        let settings = try BoardExportSettings(
            viewport: BoardSize(width: 640, height: 400),
            scale: 1,
            background: BoardColor(hexRGB: "fbfcfa")
        )
        let renderer = DeterministicBoardRenderer()

        let first = try renderer.render(document, settings: settings)
        let second = try renderer.render(document, settings: settings)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.canonicalSource.prefix(5), Data("<?xml".utf8))
        XCTAssertEqual(first.png.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        XCTAssertEqual(first.pngWidth, 640)
        XCTAssertEqual(first.pngHeight, 400)

        let svg = try XCTUnwrap(String(data: first.svg, encoding: .utf8))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 640 400\""))
        XCTAssertTrue(svg.contains("Gateway &lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(svg.contains("data-node-kind=\"service\""))
        XCTAssertTrue(svg.contains("data-node-visual=\"hexagon.fanout\""))
        XCTAssertTrue(svg.contains("<path d=\"M 99 91 L 241 91 L 259 135"))
        XCTAssertFalse(svg.contains(">SVC</text>"))
        XCTAssertFalse(svg.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(svg.localizedCaseInsensitiveContains("href="))
        XCTAssertFalse(svg.contains("/Users/"))
    }

    func testNodeKindChangesTheRasterizedCanonicalVectorVisual() throws {
        func document(kind: BoardNodeKind) throws -> BoardDocument {
            try BoardDocument(
                canvas: BoardCanvas(size: BoardSize(width: 320, height: 200)),
                elements: [
                    .box(
                        BoardBox(
                            id: BoardElementID("node"),
                            frame: BoardRect(
                                origin: BoardPoint(x: 70, y: 55),
                                size: BoardSize(width: 180, height: 90)
                            ),
                            label: "Data",
                            kind: kind
                        )
                    ),
                ]
            )
        }
        let settings = try BoardExportSettings(
            viewport: BoardSize(width: 320, height: 200),
            scale: 1,
            background: BoardColor(hexRGB: "fbfcfa")
        )
        let renderer = DeterministicBoardRenderer()

        let service = try renderer.render(document(kind: .service), settings: settings)
        let database = try renderer.render(document(kind: .database), settings: settings)

        XCTAssertNotEqual(service.png, database.png)
        XCTAssertTrue(
            try XCTUnwrap(String(data: database.svg, encoding: .utf8))
                .contains("data-node-visual=\"cylinder.records\"")
        )
    }

    func testConnectorUsesTheSameOrthogonalRouteInSVGAndPNG() throws {
        let start = BoardPoint(x: 200, y: 100)
        let end = BoardPoint(x: 460, y: 240)
        let document = try BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 640, height: 400)),
            elements: [
                .connector(
                    BoardConnector(
                        id: BoardElementID("route"),
                        start: BoardConnectorEndpoint(point: start),
                        end: BoardConnectorEndpoint(point: end),
                        label: "events"
                    )
                ),
            ]
        )
        let settings = try BoardExportSettings(
            viewport: BoardSize(width: 640, height: 400),
            scale: 1,
            background: BoardColor(hexRGB: "fbfcfa")
        )

        let first = try DeterministicBoardRenderer().render(
            document,
            settings: settings
        )
        let second = try DeterministicBoardRenderer().render(
            document,
            settings: settings
        )
        let svg = try XCTUnwrap(String(data: first.svg, encoding: .utf8))

        XCTAssertTrue(svg.contains("M 200 100 L 330 100 L 330 240 L 460 240"))
        XCTAssertEqual(first.png, second.png)
        XCTAssertNotEqual(first.png, Data())
    }

    func testRendererRejectsAViewportThatWouldExceedPixelBudget() throws {
        let renderer = DeterministicBoardRenderer(maximumPixelCount: 1_000)
        let settings = try BoardExportSettings(
            viewport: BoardSize(width: 100, height: 100),
            scale: 1,
            background: BoardColor(hexRGB: "ffffff")
        )

        XCTAssertThrowsError(
            try renderer.render(.empty, settings: settings)
        )
    }
}
