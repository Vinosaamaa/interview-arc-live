import Foundation
import InterviewArcLiveCore

enum BoardEditorTool: String, CaseIterable, Sendable {
    case select
    case box
    case connector
    case label
    case pen
    case eraser
}

enum BoardEditorError: Error, Equatable, Sendable {
    case missingElement
    case connectorRequiresDistinctBoxes
    case invalidGesture
}

enum BoardEditorAction: Sendable {
    case createBox(frame: BoardRect, label: String, kind: BoardNodeKind)
    case connect(
        sourceBoxID: BoardElementID,
        targetBoxID: BoardElementID,
        label: String
    )
    case updateLabel(id: BoardElementID, text: String)
    case createLabel(origin: BoardPoint, text: String)
    case addStroke(points: [BoardPoint])
    case eraseStroke(at: BoardPoint, radius: Double)
    case select(BoardElementID?)
    case moveSelected(by: BoardPoint)
    case deleteSelection
    case setTool(BoardEditorTool)
    case setZoom(Double)
    case resetZoom
    case undo
    case redo
}

struct BoardEditorState: Equatable, Sendable {
    static let minimumZoom = 0.25
    static let maximumZoom = 4.0
    static let maximumHistoryCount = 100

    private(set) var document: BoardDocument
    private(set) var selectedElementID: BoardElementID?
    private(set) var tool: BoardEditorTool = .select
    private(set) var zoom = 1.0

    private struct HistoryEntry: Equatable, Sendable {
        let document: BoardDocument
        let selectedElementID: BoardElementID?
    }

    private var undoHistory: [HistoryEntry] = []
    private var redoHistory: [HistoryEntry] = []

    init(document: BoardDocument) {
        self.document = document
    }

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }

    mutating func apply(_ action: BoardEditorAction) throws {
        switch action {
        case .createBox(let frame, let label, let kind):
            let id = nextElementID(prefix: "box")
            let box = BoardBox(id: id, frame: frame, label: label, kind: kind)
            try commit(elements: document.elements + [.box(box)])
            selectedElementID = id

        case .connect(let sourceBoxID, let targetBoxID, let label):
            guard sourceBoxID != targetBoxID else {
                throw BoardEditorError.connectorRequiresDistinctBoxes
            }
            guard let source = box(id: sourceBoxID),
                  let target = box(id: targetBoxID) else {
                throw BoardEditorError.missingElement
            }
            let id = nextElementID(prefix: "connector")
            let connector = BoardConnector(
                id: id,
                start: BoardConnectorEndpoint(
                    point: BoardPoint(
                        x: source.frame.origin.x + source.frame.size.width,
                        y: source.frame.origin.y + source.frame.size.height / 2
                    ),
                    elementID: source.id
                ),
                end: BoardConnectorEndpoint(
                    point: BoardPoint(
                        x: target.frame.origin.x,
                        y: target.frame.origin.y + target.frame.size.height / 2
                    ),
                    elementID: target.id
                ),
                label: label
            )
            try commit(elements: document.elements + [.connector(connector)])
            selectedElementID = id

        case .updateLabel(let id, let text):
            guard document.elements.contains(where: { $0.boardID == id }) else {
                throw BoardEditorError.missingElement
            }
            try commit(
                elements: document.elements.map { element in
                    relabel(element, id: id, text: text)
                }
            )

        case .createLabel(let origin, let text):
            let id = nextElementID(prefix: "label")
            let label = BoardLabel(id: id, origin: origin, text: text)
            try commit(elements: document.elements + [.label(label)])
            selectedElementID = id

        case .addStroke(let points):
            guard points.count >= 2 else { throw BoardEditorError.invalidGesture }
            let id = nextElementID(prefix: "stroke")
            let stroke = BoardStroke(
                id: id,
                points: points,
                width: 3,
                color: BoardColor(hexRGB: "ed4e2f")
            )
            try commit(elements: document.elements + [.stroke(stroke)])
            selectedElementID = id

        case .eraseStroke(let point, let radius):
            guard radius.isFinite, radius > 0 else {
                throw BoardEditorError.invalidGesture
            }
            let removedIDs = Set(
                document.elements.compactMap { element -> BoardElementID? in
                    guard case .stroke(let stroke) = element,
                          hit(stroke: stroke, at: point, radius: radius) else {
                        return nil
                    }
                    return stroke.id
                }
            )
            guard !removedIDs.isEmpty else { return }
            try commit(
                elements: document.elements.filter {
                    !removedIDs.contains($0.boardID)
                }
            )
            if let selectedElementID, removedIDs.contains(selectedElementID) {
                self.selectedElementID = nil
            }

        case .select(let id):
            guard id == nil || document.elements.contains(where: { $0.boardID == id }) else {
                selectedElementID = nil
                return
            }
            selectedElementID = id

        case .moveSelected(let delta):
            guard let selectedElementID else { return }
            let moved = document.elements.map { element in
                move(
                    element,
                    selectedElementID: selectedElementID,
                    delta: delta
                )
            }
            try commit(elements: moved)

        case .deleteSelection:
            guard let selectedElementID else { return }
            let retained = document.elements.filter { element in
                guard element.boardID != selectedElementID else { return false }
                guard case .connector(let connector) = element else { return true }
                return connector.start.elementID != selectedElementID
                    && connector.end.elementID != selectedElementID
            }
            try commit(elements: retained)
            self.selectedElementID = nil

        case .setTool(let tool):
            self.tool = tool

        case .setZoom(let zoom):
            guard zoom.isFinite else { throw BoardEditorError.invalidGesture }
            self.zoom = min(Self.maximumZoom, max(Self.minimumZoom, zoom))

        case .resetZoom:
            zoom = 1

        case .undo:
            guard let previous = undoHistory.popLast() else { return }
            redoHistory.append(historyEntry)
            restore(previous)

        case .redo:
            guard let next = redoHistory.popLast() else { return }
            undoHistory.append(historyEntry)
            restore(next)
        }
    }

    private mutating func commit(elements: [BoardElement]) throws {
        let next = try BoardDocument(
            schemaVersion: document.schemaVersion,
            canvas: document.canvas,
            elements: elements
        )
        guard next != document else { return }
        undoHistory.append(historyEntry)
        if undoHistory.count > Self.maximumHistoryCount {
            undoHistory.removeFirst(undoHistory.count - Self.maximumHistoryCount)
        }
        redoHistory.removeAll(keepingCapacity: true)
        document = next
    }

    private var historyEntry: HistoryEntry {
        HistoryEntry(
            document: document,
            selectedElementID: selectedElementID
        )
    }

    private mutating func restore(_ entry: HistoryEntry) {
        document = entry.document
        selectedElementID = entry.selectedElementID
    }

    private func move(
        _ element: BoardElement,
        selectedElementID: BoardElementID,
        delta: BoardPoint
    ) -> BoardElement {
        switch element {
        case .box(let box) where box.id == selectedElementID:
            return .box(
                BoardBox(
                    id: box.id,
                    frame: BoardRect(
                        origin: offset(box.frame.origin, by: delta),
                        size: box.frame.size
                    ),
                    label: box.label,
                    kind: box.kind,
                    fill: box.fill,
                    stroke: box.stroke
                )
            )
        case .connector(let connector):
            let start = connector.start.elementID == selectedElementID
                ? BoardConnectorEndpoint(
                    point: offset(connector.start.point, by: delta),
                    elementID: connector.start.elementID
                )
                : connector.start
            let end = connector.end.elementID == selectedElementID
                ? BoardConnectorEndpoint(
                    point: offset(connector.end.point, by: delta),
                    elementID: connector.end.elementID
                )
                : connector.end
            guard connector.id == selectedElementID
                    || start != connector.start
                    || end != connector.end else {
                return element
            }
            return .connector(
                BoardConnector(
                    id: connector.id,
                    start: connector.id == selectedElementID
                        ? BoardConnectorEndpoint(
                            point: offset(start.point, by: delta),
                            elementID: start.elementID
                        )
                        : start,
                    end: connector.id == selectedElementID
                        ? BoardConnectorEndpoint(
                            point: offset(end.point, by: delta),
                            elementID: end.elementID
                        )
                        : end,
                    label: connector.label,
                    stroke: connector.stroke
                )
            )
        case .label(let label) where label.id == selectedElementID:
            return .label(
                BoardLabel(
                    id: label.id,
                    origin: offset(label.origin, by: delta),
                    text: label.text,
                    color: label.color
                )
            )
        case .stroke(let stroke) where stroke.id == selectedElementID:
            return .stroke(
                BoardStroke(
                    id: stroke.id,
                    points: stroke.points.map { offset($0, by: delta) },
                    width: stroke.width,
                    color: stroke.color
                )
            )
        default:
            return element
        }
    }

    private func relabel(
        _ element: BoardElement,
        id: BoardElementID,
        text: String
    ) -> BoardElement {
        switch element {
        case .box(let box) where box.id == id:
            return .box(
                BoardBox(
                    id: box.id,
                    frame: box.frame,
                    label: text,
                    kind: box.kind,
                    fill: box.fill,
                    stroke: box.stroke
                )
            )
        case .connector(let connector) where connector.id == id:
            return .connector(
                BoardConnector(
                    id: connector.id,
                    start: connector.start,
                    end: connector.end,
                    label: text,
                    stroke: connector.stroke
                )
            )
        case .label(let label) where label.id == id:
            return .label(
                BoardLabel(
                    id: label.id,
                    origin: label.origin,
                    text: text,
                    color: label.color
                )
            )
        default:
            return element
        }
    }

    private func box(id: BoardElementID) -> BoardBox? {
        document.elements.lazy.compactMap { element in
            guard case .box(let box) = element, box.id == id else { return nil }
            return box
        }.first
    }

    private func hit(
        stroke: BoardStroke,
        at point: BoardPoint,
        radius: Double
    ) -> Bool {
        let threshold = radius + stroke.width / 2
        return zip(stroke.points, stroke.points.dropFirst()).contains {
            distance(from: point, toSegmentFrom: $0.0, to: $0.1) <= threshold
        }
    }

    private func distance(
        from point: BoardPoint,
        toSegmentFrom start: BoardPoint,
        to end: BoardPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy)
            / denominator
        let t = min(1, max(0, projection))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    private func offset(_ point: BoardPoint, by delta: BoardPoint) -> BoardPoint {
        BoardPoint(x: point.x + delta.x, y: point.y + delta.y)
    }

    private func nextElementID(prefix: String) -> BoardElementID {
        let existing = Set(document.elements.map(\.boardID))
        var ordinal = 1
        while existing.contains(BoardElementID("\(prefix)-\(ordinal)")) {
            ordinal += 1
        }
        return BoardElementID("\(prefix)-\(ordinal)")
    }
}

extension BoardElement {
    var boardID: BoardElementID {
        switch self {
        case .box(let box): box.id
        case .connector(let connector): connector.id
        case .label(let label): label.id
        case .stroke(let stroke): stroke.id
        }
    }
}
