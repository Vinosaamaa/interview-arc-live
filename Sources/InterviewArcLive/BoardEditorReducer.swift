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

enum BoardResizeHandle: String, CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
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
    case selectNext
    case selectPrevious
    case moveSelected(by: BoardPoint)
    case resizeSelected(handle: BoardResizeHandle, by: BoardPoint)
    case deleteSelection
    case setTool(BoardEditorTool)
    case setZoom(Double)
    case resetZoom
    case undo
    case redo
}

struct BoardEditorMutationResult: Equatable, Sendable {
    let documentChanged: Bool
}

struct BoardSelectionCapabilities: Equatable, Sendable {
    let canMove: Bool
    let canResize: Bool
    let canEditLabel: Bool

    init(element: BoardElement) {
        switch element {
        case .box:
            canMove = true
            canResize = true
            canEditLabel = true
        case .connector(let connector):
            canMove = connector.start.elementID == nil
                && connector.end.elementID == nil
            canResize = false
            canEditLabel = true
        case .label:
            canMove = true
            canResize = false
            canEditLabel = true
        case .stroke:
            canMove = true
            canResize = false
            canEditLabel = false
        }
    }
}

enum BoardElementLayout {
    static let labelSize = BoardSize(width: 240, height: 32)

    static func clampedLabelOrigin(
        _ requested: BoardPoint,
        in canvas: BoardSize
    ) -> BoardPoint {
        BoardPoint(
            x: min(
                max(0, requested.x),
                max(0, canvas.width - min(labelSize.width, canvas.width))
            ),
            y: min(
                max(0, requested.y),
                max(0, canvas.height - min(labelSize.height, canvas.height))
            )
        )
    }
}

struct BoardEditorState: Equatable, Sendable {
    static let minimumZoom = 0.25
    static let maximumZoom = 4.0
    static let maximumHistoryCount = 100
    static let minimumBoxWidth = 96.0
    static let minimumBoxHeight = 64.0

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
    private var documentMutationGeneration: UInt64 = 0

    init(document: BoardDocument) {
        self.document = document
    }

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }

    mutating func applyReportingMutation(
        _ action: BoardEditorAction
    ) throws -> BoardEditorMutationResult {
        let previousGeneration = documentMutationGeneration
        try apply(action)
        return BoardEditorMutationResult(
            documentChanged: documentMutationGeneration != previousGeneration
        )
    }

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
            let anchors = BoardConnectorAnchorLayout.between(
                source: source,
                target: target
            )
            let id = nextElementID(prefix: "connector")
            let connector = BoardConnector(
                id: id,
                start: BoardConnectorEndpoint(
                    point: anchors.start,
                    elementID: source.id,
                    anchorPolicy: .automatic
                ),
                end: BoardConnectorEndpoint(
                    point: anchors.end,
                    elementID: target.id,
                    anchorPolicy: .automatic
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
            let label = BoardLabel(
                id: id,
                origin: BoardElementLayout.clampedLabelOrigin(
                    origin,
                    in: document.canvas.size
                ),
                text: text
            )
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

        case .selectNext:
            selectRelativeElement(step: 1)

        case .selectPrevious:
            selectRelativeElement(step: -1)

        case .moveSelected(let delta):
            guard delta.x.isFinite, delta.y.isFinite else {
                throw BoardEditorError.invalidGesture
            }
            guard let selectedElementID,
                  let boundedDelta = boundedMoveDelta(
                    for: selectedElementID,
                    requested: delta
                  ) else {
                return
            }
            let moved = document.elements.map { element in
                move(
                    element,
                    selectedElementID: selectedElementID,
                    delta: boundedDelta
                )
            }
            try commit(
                elements: box(id: selectedElementID) == nil
                    ? moved
                    : reanchorAttachedConnectors(
                        in: moved,
                        previousElements: document.elements
                    )
            )

        case .resizeSelected(let handle, let delta):
            guard delta.x.isFinite, delta.y.isFinite else {
                throw BoardEditorError.invalidGesture
            }
            guard let selectedElementID,
                  let selectedBox = box(id: selectedElementID) else {
                return
            }
            let resized = BoardBox(
                id: selectedBox.id,
                frame: resizedFrame(
                    selectedBox.frame,
                    handle: handle,
                    delta: delta
                ),
                label: selectedBox.label,
                kind: selectedBox.kind,
                fill: selectedBox.fill,
                stroke: selectedBox.stroke
            )
            let resizedElements = document.elements.map { element in
                resize(
                    element,
                    selectedBoxID: selectedElementID,
                    resizedBox: resized
                )
            }
            try commit(
                elements: reanchorAttachedConnectors(
                    in: resizedElements,
                    previousElements: document.elements
                )
            )

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
        documentMutationGeneration &+= 1
    }

    private var historyEntry: HistoryEntry {
        HistoryEntry(
            document: document,
            selectedElementID: selectedElementID
        )
    }

    private mutating func restore(_ entry: HistoryEntry) {
        if document != entry.document {
            documentMutationGeneration &+= 1
        }
        document = entry.document
        selectedElementID = entry.selectedElementID
    }

    private mutating func selectRelativeElement(step: Int) {
        let ids = document.elements.map(\.boardID)
        guard !ids.isEmpty else {
            selectedElementID = nil
            return
        }
        guard let selectedElementID,
              let index = ids.firstIndex(of: selectedElementID) else {
            self.selectedElementID = step < 0 ? ids.last : ids.first
            return
        }
        let next = (index + step + ids.count) % ids.count
        self.selectedElementID = ids[next]
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
                    elementID: connector.start.elementID,
                    anchorPolicy: connector.start.anchorPolicy
                )
                : connector.start
            let end = connector.end.elementID == selectedElementID
                ? BoardConnectorEndpoint(
                    point: offset(connector.end.point, by: delta),
                    elementID: connector.end.elementID,
                    anchorPolicy: connector.end.anchorPolicy
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
                            elementID: start.elementID,
                            anchorPolicy: start.anchorPolicy
                        )
                        : start,
                    end: connector.id == selectedElementID
                        ? BoardConnectorEndpoint(
                            point: offset(end.point, by: delta),
                            elementID: end.elementID,
                            anchorPolicy: end.anchorPolicy
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

    private func boundedMoveDelta(
        for selectedElementID: BoardElementID,
        requested: BoardPoint
    ) -> BoardPoint? {
        guard let element = document.elements.first(where: {
            $0.boardID == selectedElementID
        }) else {
            return nil
        }
        let capabilities = BoardSelectionCapabilities(element: element)
        guard capabilities.canMove else { return nil }

        let bounds: (minX: Double, maxX: Double, minY: Double, maxY: Double)
        switch element {
        case .box(let box):
            bounds = (
                box.frame.origin.x,
                box.frame.origin.x + box.frame.size.width,
                box.frame.origin.y,
                box.frame.origin.y + box.frame.size.height
            )
        case .connector(let connector):
            bounds = (
                min(connector.start.point.x, connector.end.point.x),
                max(connector.start.point.x, connector.end.point.x),
                min(connector.start.point.y, connector.end.point.y),
                max(connector.start.point.y, connector.end.point.y)
            )
        case .label(let label):
            let width = min(
                BoardElementLayout.labelSize.width,
                document.canvas.size.width
            )
            let height = min(
                BoardElementLayout.labelSize.height,
                document.canvas.size.height
            )
            bounds = (
                label.origin.x,
                label.origin.x + width,
                label.origin.y,
                label.origin.y + height
            )
        case .stroke(let stroke):
            guard let first = stroke.points.first else {
                return nil
            }
            bounds = stroke.points.dropFirst().reduce(
                (
                    minX: first.x,
                    maxX: first.x,
                    minY: first.y,
                    maxY: first.y
                )
            ) { bounds, point in
                (
                    min(bounds.minX, point.x),
                    max(bounds.maxX, point.x),
                    min(bounds.minY, point.y),
                    max(bounds.maxY, point.y)
                )
            }
        }

        guard let x = boundedAxisDelta(
            requested.x,
            minimum: bounds.minX,
            maximum: bounds.maxX,
            limit: document.canvas.size.width
        ), let y = boundedAxisDelta(
            requested.y,
            minimum: bounds.minY,
            maximum: bounds.maxY,
            limit: document.canvas.size.height
        ) else {
            return nil
        }
        return BoardPoint(x: x, y: y)
    }

    private func boundedAxisDelta(
        _ requested: Double,
        minimum: Double,
        maximum: Double,
        limit: Double
    ) -> Double? {
        guard maximum - minimum <= limit else { return nil }
        let lowerBound = -minimum
        let upperBound = limit - maximum
        return min(max(requested, lowerBound), upperBound)
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

    private func resize(
        _ element: BoardElement,
        selectedBoxID: BoardElementID,
        resizedBox: BoardBox
    ) -> BoardElement {
        switch element {
        case .box(let box) where box.id == selectedBoxID:
            return .box(resizedBox)
        case .connector:
            return element
        default:
            return element
        }
    }

    private func resizedFrame(
        _ frame: BoardRect,
        handle: BoardResizeHandle,
        delta: BoardPoint
    ) -> BoardRect {
        let canvas = document.canvas.size
        let minimumWidth = min(Self.minimumBoxWidth, canvas.width)
        let minimumHeight = min(Self.minimumBoxHeight, canvas.height)
        let normalizedWidth = min(
            canvas.width,
            max(minimumWidth, frame.size.width)
        )
        let normalizedHeight = min(
            canvas.height,
            max(minimumHeight, frame.size.height)
        )
        var minX = min(
            max(0, frame.origin.x),
            canvas.width - normalizedWidth
        )
        var minY = min(
            max(0, frame.origin.y),
            canvas.height - normalizedHeight
        )
        var maxX = minX + normalizedWidth
        var maxY = minY + normalizedHeight

        switch handle {
        case .topLeading:
            minX = min(max(0, minX + delta.x), maxX - minimumWidth)
            minY = min(max(0, minY + delta.y), maxY - minimumHeight)
        case .topTrailing:
            maxX = min(canvas.width, max(minX + minimumWidth, maxX + delta.x))
            minY = min(max(0, minY + delta.y), maxY - minimumHeight)
        case .bottomLeading:
            minX = min(max(0, minX + delta.x), maxX - minimumWidth)
            maxY = min(canvas.height, max(minY + minimumHeight, maxY + delta.y))
        case .bottomTrailing:
            maxX = min(canvas.width, max(minX + minimumWidth, maxX + delta.x))
            maxY = min(canvas.height, max(minY + minimumHeight, maxY + delta.y))
        }

        return BoardRect(
            origin: BoardPoint(x: minX, y: minY),
            size: BoardSize(width: maxX - minX, height: maxY - minY)
        )
    }

    private func reanchorAttachedConnectors(
        in elements: [BoardElement],
        previousElements: [BoardElement]
    ) -> [BoardElement] {
        let boxes: [BoardElementID: BoardBox] = Dictionary(
            uniqueKeysWithValues: elements.compactMap { element
                -> (BoardElementID, BoardBox)? in
                guard case .box(let box) = element else { return nil }
                return (box.id, box)
            }
        )
        let previousBoxes: [BoardElementID: BoardBox] = Dictionary(
            uniqueKeysWithValues: previousElements.compactMap { element
                -> (BoardElementID, BoardBox)? in
                guard case .box(let box) = element else { return nil }
                return (box.id, box)
            }
        )
        let previousConnectors: [BoardElementID: BoardConnector] = Dictionary(
            uniqueKeysWithValues: previousElements.compactMap { element
                -> (BoardElementID, BoardConnector)? in
                guard case .connector(let connector) = element else {
                    return nil
                }
                return (connector.id, connector)
            }
        )
        return elements.map { element in
            guard case .connector(let connector) = element else {
                return element
            }

            if let sourceID = connector.start.elementID,
               let targetID = connector.end.elementID,
               let source = boxes[sourceID],
               let target = boxes[targetID] {
                let previous = previousConnectors[connector.id]
                let sourceAnchor = previous.flatMap { previous in
                    previousBoxes[sourceID].map {
                        BoardConnectorAnchorLayout.normalizedAnchor(
                            for: previous.start.point,
                            on: $0
                        )
                    }
                }
                let targetAnchor = previous.flatMap { previous in
                    previousBoxes[targetID].map {
                        BoardConnectorAnchorLayout.normalizedAnchor(
                            for: previous.end.point,
                            on: $0
                        )
                    }
                }
                let automatic = BoardConnectorAnchorLayout.between(
                    source: source,
                    target: target
                )
                let startPoint = connector.start.anchorPolicy == .automatic
                    ? automatic.start
                    : sourceAnchor?.point(in: source.frame)
                        ?? BoardConnectorAnchorLayout.anchor(
                            on: source,
                            toward: connector.end.point
                        )
                let endPoint = connector.end.anchorPolicy == .automatic
                    ? automatic.end
                    : targetAnchor?.point(in: target.frame)
                        ?? BoardConnectorAnchorLayout.anchor(
                            on: target,
                            toward: connector.start.point
                        )
                return .connector(
                    BoardConnector(
                        id: connector.id,
                        start: BoardConnectorEndpoint(
                            point: startPoint,
                            elementID: sourceID,
                            anchorPolicy: connector.start.anchorPolicy
                        ),
                        end: BoardConnectorEndpoint(
                            point: endPoint,
                            elementID: targetID,
                            anchorPolicy: connector.end.anchorPolicy
                        ),
                        label: connector.label,
                        stroke: connector.stroke
                    )
                )
            }

            let previous = previousConnectors[connector.id]
            let start = connector.start.elementID.flatMap { id in
                boxes[id].map { box in
                    let normalized = connector.start.anchorPolicy == .preserved
                        ? previous.flatMap { previous in
                            previousBoxes[id].map {
                                BoardConnectorAnchorLayout.normalizedAnchor(
                                    for: previous.start.point,
                                    on: $0
                                )
                            }
                        } : nil
                    return BoardConnectorEndpoint(
                        point: normalized?.point(in: box.frame)
                            ?? BoardConnectorAnchorLayout.anchor(
                                on: box,
                                toward: connector.end.point
                            ),
                        elementID: id,
                        anchorPolicy: connector.start.anchorPolicy
                    )
                }
            } ?? connector.start
            let end = connector.end.elementID.flatMap { id in
                boxes[id].map { box in
                    let normalized = connector.end.anchorPolicy == .preserved
                        ? previous.flatMap { previous in
                            previousBoxes[id].map {
                                BoardConnectorAnchorLayout.normalizedAnchor(
                                    for: previous.end.point,
                                    on: $0
                                )
                            }
                        } : nil
                    return BoardConnectorEndpoint(
                        point: normalized?.point(in: box.frame)
                            ?? BoardConnectorAnchorLayout.anchor(
                                on: box,
                                toward: start.point
                            ),
                        elementID: id,
                        anchorPolicy: connector.end.anchorPolicy
                    )
                }
            } ?? connector.end
            return .connector(
                BoardConnector(
                    id: connector.id,
                    start: start,
                    end: end,
                    label: connector.label,
                    stroke: connector.stroke
                )
            )
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
