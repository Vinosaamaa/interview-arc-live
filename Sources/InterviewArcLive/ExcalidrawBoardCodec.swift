import Foundation
import InterviewArcLiveCore

enum ExcalidrawBoardCodecError: Error, Equatable, Sendable {
    case messageTooLarge
    case unsupportedElements(count: Int)
    case tooManyElements
    case invalidElement
    case invalidConnector
}

enum ExcalidrawBoardBridgePolicy {
    static let flushedCommandEvent = "flushedCommand"

    static func permitsScene(afterNativeBaselineWasSent wasSent: Bool) -> Bool {
        wasSent
    }

    static func permitsCommand(afterSceneAccepted accepted: Bool) -> Bool {
        accepted
    }
}

struct ExcalidrawBoardSceneChange: Decodable, Sendable {
    let event: String
    let elements: [ExcalidrawBoardElement]
    let selectedWebIDs: [String]
    let unsupportedElementCount: Int
    let zoom: Double?
    let tool: String?
    let boxKind: String?
}

struct ExcalidrawBoardDecodeResult: Equatable, Sendable {
    let document: BoardDocument
    let selectedElementID: BoardElementID?
    let boardIDsByWebID: [String: BoardElementID]
    let zoom: Double?
    let tool: BoardEditorTool?
    let boxKind: BoardNodeKind?
    let requiresReload: Bool
}

struct ExcalidrawBoardControls: Encodable, Equatable, Sendable {
    let revisionStatus: String
    let notice: String?
    let noticeIsError: Bool
    let isInspecting: Bool
    let canSave: Bool
    let hasRevisions: Bool
    let canAttach: Bool
    let canExport: Bool
    let isExporting: Bool
}

struct ExcalidrawBoardScene: Encodable, Sendable {
    let elements: [ExcalidrawBoardElement]
    let selectedID: String?
    let zoom: Double
    let readOnly: Bool
    let tool: String
    let boxKind: String
    let controls: ExcalidrawBoardControls

    init(
        document: BoardDocument,
        selectedElementID: BoardElementID?,
        zoom: Double,
        readOnly: Bool,
        tool: BoardEditorTool,
        boxKind: BoardNodeKind,
        controls: ExcalidrawBoardControls
    ) {
        elements = BoardRenderOrder.elements(in: document).map(
            ExcalidrawBoardElement.init
        )
        selectedID = selectedElementID?.rawValue
        self.zoom = zoom
        self.readOnly = readOnly
        self.tool = tool.rawValue
        self.boxKind = boxKind.rawValue
        self.controls = controls
    }
}

struct ExcalidrawBoardState: Encodable, Equatable, Sendable {
    let selectedID: String?
    let zoom: Double
    let readOnly: Bool
    let tool: String
    let boxKind: String
    let controls: ExcalidrawBoardControls
}

enum ExcalidrawBoardUpdatePolicy {
    static func requiresStateUpdate(
        previous: ExcalidrawBoardState?,
        next: ExcalidrawBoardState
    ) -> Bool {
        previous != next
    }
}

struct ExcalidrawBoardObservationGate: Equatable, Sendable {
    private(set) var webSceneCallbackDepth = 0

    var permitsNativeObservation: Bool {
        webSceneCallbackDepth == 0
    }

    mutating func beginWebSceneCallback() {
        webSceneCallbackDepth += 1
    }

    mutating func endWebSceneCallback() {
        precondition(webSceneCallbackDepth > 0)
        webSceneCallbackDepth -= 1
    }
}

struct ExcalidrawBoardElement: Codable, Equatable, Sendable {
    let type: String
    let webID: String?
    let boardID: String?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let label: String?
    let nodeKind: String?
    let fill: String?
    let stroke: String?
    let startX: Double?
    let startY: Double?
    let endX: Double?
    let endY: Double?
    let sourceWebID: String?
    let targetWebID: String?
    let sourceID: String?
    let targetID: String?
    let startAnchorPolicy: String?
    let endAnchorPolicy: String?
    let text: String?
    let color: String?
    let points: [BoardPoint]?

    init(_ element: BoardElement) {
        switch element {
        case .box(let box):
            type = "box"
            boardID = box.id.rawValue
            x = box.frame.origin.x
            y = box.frame.origin.y
            width = box.frame.size.width
            height = box.frame.size.height
            label = box.label
            nodeKind = box.kind.rawValue
            fill = Self.hex(box.fill)
            stroke = Self.hex(box.stroke)
            startX = nil
            startY = nil
            endX = nil
            endY = nil
            sourceID = nil
            targetID = nil
            startAnchorPolicy = nil
            endAnchorPolicy = nil
            text = nil
            color = nil
            points = nil

        case .connector(let connector):
            type = "connector"
            boardID = connector.id.rawValue
            x = nil
            y = nil
            width = nil
            height = nil
            label = connector.label
            nodeKind = nil
            fill = nil
            stroke = Self.hex(connector.stroke)
            startX = connector.start.point.x
            startY = connector.start.point.y
            endX = connector.end.point.x
            endY = connector.end.point.y
            sourceID = connector.start.elementID?.rawValue
            targetID = connector.end.elementID?.rawValue
            startAnchorPolicy = connector.start.anchorPolicy.rawValue
            endAnchorPolicy = connector.end.anchorPolicy.rawValue
            text = nil
            color = nil
            points = BoardOrthogonalConnectorRoute(
                start: connector.start.point,
                end: connector.end.point
            ).points

        case .label(let boardLabel):
            type = "label"
            boardID = boardLabel.id.rawValue
            x = boardLabel.origin.x
            y = boardLabel.origin.y
            width = nil
            height = nil
            label = nil
            nodeKind = nil
            fill = nil
            stroke = nil
            startX = nil
            startY = nil
            endX = nil
            endY = nil
            sourceID = nil
            targetID = nil
            startAnchorPolicy = nil
            endAnchorPolicy = nil
            text = boardLabel.text
            color = Self.hex(boardLabel.color)
            points = nil

        case .stroke(let boardStroke):
            type = "stroke"
            boardID = boardStroke.id.rawValue
            x = nil
            y = nil
            width = boardStroke.width
            height = nil
            label = nil
            nodeKind = nil
            fill = nil
            stroke = nil
            startX = nil
            startY = nil
            endX = nil
            endY = nil
            sourceID = nil
            targetID = nil
            startAnchorPolicy = nil
            endAnchorPolicy = nil
            text = nil
            color = Self.hex(boardStroke.color)
            points = boardStroke.points
        }
        webID = nil
        sourceWebID = nil
        targetWebID = nil
    }

    private static func hex(_ color: BoardColor) -> String {
        "#\(color.hexRGB.lowercased())"
    }
}

enum ExcalidrawBoardCodec {
    static let maximumBridgeBytes = 8 * 1_024 * 1_024

    static func encodeScene(_ scene: ExcalidrawBoardScene) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encodedString(scene, encoder: encoder)
    }

    static func encodeState(_ state: ExcalidrawBoardState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encodedString(state, encoder: encoder)
    }

    static func decodeChange(
        from object: Any,
        currentDocument: BoardDocument,
        preferredBoardIDsByWebID: [String: BoardElementID] = [:]
    ) throws -> ExcalidrawBoardDecodeResult {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ExcalidrawBoardCodecError.invalidElement
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= maximumBridgeBytes else {
            throw ExcalidrawBoardCodecError.messageTooLarge
        }
        let change = try JSONDecoder().decode(
            ExcalidrawBoardSceneChange.self,
            from: data
        )
        guard change.event == "scene" else {
            throw ExcalidrawBoardCodecError.invalidElement
        }
        guard change.unsupportedElementCount == 0 else {
            throw ExcalidrawBoardCodecError.unsupportedElements(
                count: change.unsupportedElementCount
            )
        }
        guard change.elements.count <= BoardDocument.maximumElements else {
            throw ExcalidrawBoardCodecError.tooManyElements
        }

        let existingTypes = Dictionary(
            uniqueKeysWithValues: currentDocument.elements.map {
                ($0.id, elementType($0))
            }
        )
        let existingIDs = Set(existingTypes.keys)
        var usedIDs = Set<BoardElementID>()
        var usedWebIDs = Set<String>()
        var webIDToBoardID: [String: BoardElementID] = [:]
        var assignedIDs: [BoardElementID] = []
        var requiresReload = false

        for element in change.elements {
            guard let webID = element.webID,
                  !webID.isEmpty,
                  usedWebIDs.insert(webID).inserted,
                  let elementPrefix = prefix(for: element.type) else {
                throw ExcalidrawBoardCodecError.invalidElement
            }
            let candidate = element.boardID.map { BoardElementID($0) }
            let assigned: BoardElementID
            if let candidate,
               existingIDs.contains(candidate),
               existingTypes[candidate] == element.type,
               usedIDs.insert(candidate).inserted {
                assigned = candidate
            } else if let remembered = preferredBoardIDsByWebID[webID],
                      (existingTypes[remembered] == element.type
                        || !existingIDs.contains(remembered)),
                      usedIDs.insert(remembered).inserted {
                // A newly drawn Excalidraw element has no canonical Board ID
                // until the native reconcile lands. Reuse the ID assigned to
                // that web identity across any scenes published in between;
                // allocating again would make selection jump to another box.
                assigned = remembered
                requiresReload = true
            } else {
                assigned = nextID(
                    prefix: elementPrefix,
                    usedIDs: usedIDs.union(existingIDs)
                )
                usedIDs.insert(assigned)
                requiresReload = true
            }
            assignedIDs.append(assigned)
            webIDToBoardID[webID] = assigned
        }

        let boxIDs = Set(
            zip(change.elements, assignedIDs).compactMap { pair in
                let (element, id) = pair
                return element.type == "box" ? id : nil
            }
        )
        var elements: [BoardElement] = []
        elements.reserveCapacity(change.elements.count)

        for (element, id) in zip(change.elements, assignedIDs) {
            switch element.type {
            case "box":
                elements.append(
                    .box(try makeBox(element, id: id))
                )
            case "connector":
                elements.append(
                    .connector(
                        try makeConnector(
                            element,
                            id: id,
                            webIDToBoardID: webIDToBoardID,
                            boxIDs: boxIDs
                        )
                    )
                )
            case "label":
                elements.append(
                    .label(try makeLabel(element, id: id))
                )
            case "stroke":
                elements.append(
                    .stroke(try makeStroke(element, id: id))
                )
            default:
                throw ExcalidrawBoardCodecError.invalidElement
            }
        }

        let document = try BoardDocument(
            schemaVersion: currentDocument.schemaVersion,
            canvas: currentDocument.canvas,
            elements: elements
        )
        if !requiresReload {
            requiresReload = zip(change.elements, document.elements).contains {
                source, canonical in
                requiresCanonicalReload(
                    source,
                    canonical: canonical,
                    webIDToBoardID: webIDToBoardID
                )
            }
        }
        let selectedElementID = change.selectedWebIDs.lazy.compactMap {
            webIDToBoardID[$0]
        }.first
        return ExcalidrawBoardDecodeResult(
            document: document,
            selectedElementID: selectedElementID,
            boardIDsByWebID: webIDToBoardID,
            zoom: change.zoom.flatMap { value in
                guard value.isFinite else { return nil }
                return clamp(
                    value,
                    minimum: BoardEditorState.minimumZoom,
                    maximum: BoardEditorState.maximumZoom
                )
            },
            tool: change.tool.flatMap(BoardEditorTool.init(rawValue:)),
            boxKind: change.boxKind.flatMap(BoardNodeKind.init(rawValue:)),
            requiresReload: requiresReload
        )
    }

    private static func makeBox(
        _ element: ExcalidrawBoardElement,
        id: BoardElementID
    ) throws -> BoardBox {
        guard let rawX = element.x,
              let rawY = element.y,
              let rawWidth = element.width,
              let rawHeight = element.height,
              rawX.isFinite,
              rawY.isFinite,
              rawWidth.isFinite,
              rawHeight.isFinite,
              rawWidth > 0,
              rawHeight > 0,
              rawWidth <= BoardDocument.maximumCanvasDimension,
              rawHeight <= BoardDocument.maximumCanvasDimension else {
            throw ExcalidrawBoardCodecError.invalidElement
        }
        guard let kind = BoardNodeKind(rawValue: element.nodeKind ?? "") else {
            throw ExcalidrawBoardCodecError.invalidElement
        }
        return BoardBox(
            id: id,
            frame: BoardRect(
                origin: BoardPoint(x: rawX, y: rawY),
                size: BoardSize(width: rawWidth, height: rawHeight)
            ),
            label: element.label ?? "",
            kind: kind,
            fill: try color(element.fill, fallback: .white),
            stroke: try color(element.stroke, fallback: .nodeOutline)
        )
    }

    private static func makeConnector(
        _ element: ExcalidrawBoardElement,
        id: BoardElementID,
        webIDToBoardID: [String: BoardElementID],
        boxIDs: Set<BoardElementID>
    ) throws -> BoardConnector {
        guard let startX = element.startX,
              let startY = element.startY,
              let endX = element.endX,
              let endY = element.endY,
              [startX, startY, endX, endY].allSatisfy(\.isFinite) else {
            throw ExcalidrawBoardCodecError.invalidConnector
        }
        let sourceID = element.sourceWebID.flatMap { webIDToBoardID[$0] }
        let targetID = element.targetWebID.flatMap { webIDToBoardID[$0] }
        guard sourceID.map(boxIDs.contains) ?? true,
              targetID.map(boxIDs.contains) ?? true,
              sourceID == nil || targetID == nil || sourceID != targetID else {
            throw ExcalidrawBoardCodecError.invalidConnector
        }
        return BoardConnector(
            id: id,
            start: BoardConnectorEndpoint(
                point: BoardPoint(x: startX, y: startY),
                elementID: sourceID,
                anchorPolicy: anchorPolicy(
                    element.startAnchorPolicy,
                    hasBinding: sourceID != nil
                )
            ),
            end: BoardConnectorEndpoint(
                point: BoardPoint(x: endX, y: endY),
                elementID: targetID,
                anchorPolicy: anchorPolicy(
                    element.endAnchorPolicy,
                    hasBinding: targetID != nil
                )
            ),
            label: element.label ?? "",
            stroke: try color(element.stroke, fallback: .ink)
        )
    }

    private static func makeLabel(
        _ element: ExcalidrawBoardElement,
        id: BoardElementID
    ) throws -> BoardLabel {
        guard let x = element.x, let y = element.y,
              x.isFinite, y.isFinite else {
            throw ExcalidrawBoardCodecError.invalidElement
        }
        return BoardLabel(
            id: id,
            origin: BoardPoint(x: x, y: y),
            text: element.text ?? "",
            color: try color(element.color, fallback: .ink)
        )
    }

    private static func makeStroke(
        _ element: ExcalidrawBoardElement,
        id: BoardElementID
    ) throws -> BoardStroke {
        guard let points = element.points,
              points.count >= 2,
              let width = element.width,
              width.isFinite,
              width > 0,
              width <= BoardDocument.maximumStrokeWidth else {
            throw ExcalidrawBoardCodecError.invalidElement
        }
        return BoardStroke(
            id: id,
            points: points,
            width: width,
            color: try color(element.color, fallback: BoardColor(hexRGB: "ed4e2f"))
        )
    }

    private static func anchorPolicy(
        _ rawValue: String?,
        hasBinding: Bool
    ) -> BoardConnectorAnchorPolicy {
        guard hasBinding else { return .preserved }
        return BoardConnectorAnchorPolicy(rawValue: rawValue ?? "") ?? .automatic
    }

    private static func requiresCanonicalReload(
        _ source: ExcalidrawBoardElement,
        canonical: BoardElement,
        webIDToBoardID: [String: BoardElementID]
    ) -> Bool {
        let encoded = ExcalidrawBoardElement(canonical)
        switch canonical {
        case .box:
            return source.x != encoded.x
                || source.y != encoded.y
                || source.width != encoded.width
                || source.height != encoded.height
                || source.label != encoded.label
                || source.nodeKind != encoded.nodeKind
                || normalizedColor(source.fill) != encoded.fill
                || normalizedColor(source.stroke) != encoded.stroke

        case .connector:
            return source.startX != encoded.startX
                || source.startY != encoded.startY
                || source.endX != encoded.endX
                || source.endY != encoded.endY
                || source.points != encoded.points
                || source.label != encoded.label
                || normalizedColor(source.stroke) != encoded.stroke
                || source.startAnchorPolicy != encoded.startAnchorPolicy
                || source.endAnchorPolicy != encoded.endAnchorPolicy
                || source.sourceWebID.flatMap { webIDToBoardID[$0] }?.rawValue
                    != encoded.sourceID
                || source.targetWebID.flatMap { webIDToBoardID[$0] }?.rawValue
                    != encoded.targetID

        case .label:
            return source.x != encoded.x
                || source.y != encoded.y
                || source.text != encoded.text
                || normalizedColor(source.color) != encoded.color

        case .stroke:
            return source.points != encoded.points
                || source.width != encoded.width
                || normalizedColor(source.color) != encoded.color
        }
    }

    private static func normalizedColor(_ value: String?) -> String? {
        value.map { rawValue in
            let value = rawValue.hasPrefix("#")
                ? rawValue
                : "#\(rawValue)"
            return value.lowercased()
        }
    }

    private static func color(
        _ value: String?,
        fallback: BoardColor
    ) throws -> BoardColor {
        guard let value else { return fallback }
        let normalized = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard normalized.count == 6,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
              }) else {
            throw ExcalidrawBoardCodecError.invalidElement
        }
        return BoardColor(hexRGB: normalized.lowercased())
    }

    private static func prefix(for type: String) -> String? {
        switch type {
        case "box": "box"
        case "connector": "connector"
        case "label": "label"
        case "stroke": "stroke"
        default: nil
        }
    }

    private static func elementType(_ element: BoardElement) -> String {
        switch element {
        case .box: "box"
        case .connector: "connector"
        case .label: "label"
        case .stroke: "stroke"
        }
    }

    private static func nextID(
        prefix: String,
        usedIDs: Set<BoardElementID>
    ) -> BoardElementID {
        var ordinal = 1
        while usedIDs.contains(BoardElementID("\(prefix)-\(ordinal)")) {
            ordinal += 1
        }
        return BoardElementID("\(prefix)-\(ordinal)")
    }

    private static func clamp(
        _ value: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard value.isFinite else { return minimum }
        return min(max(value, minimum), maximum)
    }

    private static func encodedString<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder
    ) throws -> String {
        let data = try encoder.encode(value)
        guard data.count <= maximumBridgeBytes,
              let string = String(data: data, encoding: .utf8) else {
            throw ExcalidrawBoardCodecError.messageTooLarge
        }
        return string
    }
}

enum ExcalidrawBoardToolPolicy {
    static func returnsToSelect(
        afterAdding elements: [BoardElement],
        with tool: BoardEditorTool
    ) -> Bool {
        switch tool {
        case .box:
            elements.contains { if case .box = $0 { true } else { false } }
        case .label:
            elements.contains { if case .label = $0 { true } else { false } }
        case .connector:
            elements.contains { if case .connector = $0 { true } else { false } }
        case .hand, .select, .line, .pen, .eraser:
            false
        }
    }
}
