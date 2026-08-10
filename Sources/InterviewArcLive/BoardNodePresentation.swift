import CoreGraphics
import Foundation
import InterviewArcLiveCore

extension BoardNodeKind {
    static let selectableKinds: [BoardNodeKind] = [
        .client,
        .service,
        .database,
        .queue,
        .storage,
        .generic,
    ]

    var displayName: String {
        switch self {
        case .generic: "Generic"
        case .client: "Web client"
        case .service: "Service"
        case .database: "Database"
        case .queue: "Queue"
        case .storage: "Storage"
        }
    }

    var visual: BoardNodeVisual {
        BoardNodeVisual(kind: self)
    }
}

/// One deterministic semantic vocabulary for node shape and pictogram. Live,
/// SVG, PNG, and Draw.io presentations consume this value instead of guessing
/// a visual from the node label.
struct BoardNodeVisual: Equatable {
    enum Outline: String, Equatable {
        case roundedRectangle
        case browser
        case hexagon
        case cylinder
        case queue
        case folder
    }

    enum Pictogram: String, Equatable {
        case componentGrid
        case globe
        case fanout
        case records
        case messageQueue
        case archive
    }

    let kind: BoardNodeKind
    let outline: Outline
    let pictogram: Pictogram
    let accessibilityName: String
    let drawIOShapeStyle: String

    init(kind: BoardNodeKind) {
        self.kind = kind
        switch kind {
        case .generic:
            outline = .roundedRectangle
            pictogram = .componentGrid
            accessibilityName = "Generic architecture component"
            drawIOShapeStyle = "shape=rectangle;rounded=1"
        case .client:
            outline = .browser
            pictogram = .globe
            accessibilityName = "Web client"
            drawIOShapeStyle = "shape=rectangle;rounded=1"
        case .service:
            outline = .hexagon
            pictogram = .fanout
            accessibilityName = "Service"
            drawIOShapeStyle = "shape=hexagon;perimeter=hexagonPerimeter2;fixedSize=1"
        case .database:
            outline = .cylinder
            pictogram = .records
            accessibilityName = "Database"
            drawIOShapeStyle = "shape=cylinder3;boundedLbl=1;backgroundOutline=1"
        case .queue:
            outline = .queue
            pictogram = .messageQueue
            accessibilityName = "Message queue"
            drawIOShapeStyle = "shape=process;rounded=1"
        case .storage:
            outline = .folder
            pictogram = .archive
            accessibilityName = "Object storage"
            drawIOShapeStyle = "shape=folder"
        }
    }

    var stableKey: String {
        "\(outline.rawValue).\(pictogram.rawValue)"
    }

    func outlinePath(in rect: CGRect) -> BoardVectorPath {
        let inset = rect.insetBy(dx: 1, dy: 1)
        switch outline {
        case .roundedRectangle:
            return .roundedRectangle(inset, radius: 11)
        case .browser:
            return .roundedRectangle(inset, radius: 9)
        case .hexagon:
            let shoulder = min(18, inset.width * 0.14)
            return BoardVectorPath(commands: [
                .move(CGPoint(x: inset.minX + shoulder, y: inset.minY)),
                .line(CGPoint(x: inset.maxX - shoulder, y: inset.minY)),
                .line(CGPoint(x: inset.maxX, y: inset.midY)),
                .line(CGPoint(x: inset.maxX - shoulder, y: inset.maxY)),
                .line(CGPoint(x: inset.minX + shoulder, y: inset.maxY)),
                .line(CGPoint(x: inset.minX, y: inset.midY)),
                .close,
            ])
        case .cylinder:
            let cap = min(12, inset.height * 0.16)
            let control = inset.width * 0.28
            return BoardVectorPath(commands: [
                .move(CGPoint(x: inset.minX, y: inset.minY + cap)),
                .curve(
                    control1: CGPoint(x: inset.minX, y: inset.minY),
                    control2: CGPoint(x: inset.midX - control, y: inset.minY),
                    end: CGPoint(x: inset.midX, y: inset.minY)
                ),
                .curve(
                    control1: CGPoint(x: inset.midX + control, y: inset.minY),
                    control2: CGPoint(x: inset.maxX, y: inset.minY),
                    end: CGPoint(x: inset.maxX, y: inset.minY + cap)
                ),
                .line(CGPoint(x: inset.maxX, y: inset.maxY - cap)),
                .curve(
                    control1: CGPoint(x: inset.maxX, y: inset.maxY),
                    control2: CGPoint(x: inset.midX + control, y: inset.maxY),
                    end: CGPoint(x: inset.midX, y: inset.maxY)
                ),
                .curve(
                    control1: CGPoint(x: inset.midX - control, y: inset.maxY),
                    control2: CGPoint(x: inset.minX, y: inset.maxY),
                    end: CGPoint(x: inset.minX, y: inset.maxY - cap)
                ),
                .close,
            ])
        case .queue:
            let notch = min(12, inset.width * 0.08)
            return BoardVectorPath(commands: [
                .move(CGPoint(x: inset.minX + notch, y: inset.minY)),
                .line(CGPoint(x: inset.maxX, y: inset.minY)),
                .line(CGPoint(x: inset.maxX - notch, y: inset.maxY)),
                .line(CGPoint(x: inset.minX, y: inset.maxY)),
                .close,
            ])
        case .folder:
            let tabWidth = min(52, inset.width * 0.36)
            let tabHeight = min(13, inset.height * 0.17)
            return BoardVectorPath(commands: [
                .move(CGPoint(x: inset.minX, y: inset.minY + tabHeight)),
                .line(CGPoint(x: inset.minX + tabWidth * 0.42, y: inset.minY + tabHeight)),
                .line(CGPoint(x: inset.minX + tabWidth * 0.58, y: inset.minY)),
                .line(CGPoint(x: inset.minX + tabWidth, y: inset.minY)),
                .line(CGPoint(x: inset.minX + tabWidth * 1.16, y: inset.minY + tabHeight)),
                .line(CGPoint(x: inset.maxX, y: inset.minY + tabHeight)),
                .line(CGPoint(x: inset.maxX, y: inset.maxY)),
                .line(CGPoint(x: inset.minX, y: inset.maxY)),
                .close,
            ])
        }
    }

    func detailPaths(in rect: CGRect) -> [BoardVectorPath] {
        switch outline {
        case .browser:
            let top = rect.minY + min(15, rect.height * 0.18)
            return [
                .line(
                    from: CGPoint(x: rect.minX + 1, y: top),
                    to: CGPoint(x: rect.maxX - 1, y: top)
                ),
                .ellipse(in: CGRect(x: rect.minX + 7, y: rect.minY + 5, width: 3, height: 3)),
                .ellipse(in: CGRect(x: rect.minX + 13, y: rect.minY + 5, width: 3, height: 3)),
                .ellipse(in: CGRect(x: rect.minX + 19, y: rect.minY + 5, width: 3, height: 3)),
            ]
        case .cylinder:
            let cap = min(12, rect.height * 0.16)
            return [
                .ellipse(in: CGRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 2, height: cap * 2)),
            ]
        case .queue:
            return [
                .line(
                    from: CGPoint(x: rect.minX + 9, y: rect.minY + 8),
                    to: CGPoint(x: rect.maxX - 3, y: rect.minY + 8)
                ),
                .line(
                    from: CGPoint(x: rect.minX + 5, y: rect.maxY - 8),
                    to: CGPoint(x: rect.maxX - 9, y: rect.maxY - 8)
                ),
            ]
        default:
            return []
        }
    }

    func pictogramPaths(in rect: CGRect) -> [BoardVectorPath] {
        let icon = pictogramRect(in: rect)
        let x = icon.minX
        let y = icon.minY
        let w = icon.width
        let h = icon.height
        let unit = min(1, w / 28, h / 22)
        switch pictogram {
        case .componentGrid:
            let side = min(8 * unit, h * 0.32)
            return [
                .roundedRectangle(CGRect(x: x + 4 * unit, y: y + 3 * unit, width: side, height: side), radius: 2 * unit),
                .roundedRectangle(CGRect(x: icon.maxX - side - 4 * unit, y: y + 3 * unit, width: side, height: side), radius: 2 * unit),
                .roundedRectangle(CGRect(x: x + 4 * unit, y: icon.maxY - side - 3 * unit, width: side, height: side), radius: 2 * unit),
                .roundedRectangle(CGRect(x: icon.maxX - side - 4 * unit, y: icon.maxY - side - 3 * unit, width: side, height: side), radius: 2 * unit),
            ]
        case .globe:
            let globe = CGRect(
                x: x + 5 * unit,
                y: y + unit,
                width: w - 10 * unit,
                height: h - 2 * unit
            )
            return [
                .ellipse(in: globe),
                .ellipse(in: globe.insetBy(dx: globe.width * 0.29, dy: 0)),
                .line(
                    from: CGPoint(x: globe.minX, y: globe.midY),
                    to: CGPoint(x: globe.maxX, y: globe.midY)
                ),
            ]
        case .fanout:
            let center = CGPoint(x: icon.midX, y: icon.midY)
            let left = CGPoint(x: x + 5 * unit, y: y + 5 * unit)
            let upperRight = CGPoint(
                x: icon.maxX - 5 * unit,
                y: y + 4 * unit
            )
            let lowerRight = CGPoint(
                x: icon.maxX - 5 * unit,
                y: icon.maxY - 4 * unit
            )
            return [
                .line(from: center, to: left),
                .line(from: center, to: upperRight),
                .line(from: center, to: lowerRight),
                .ellipse(centeredAt: left, radius: 3.5 * unit),
                .ellipse(centeredAt: center, radius: 3.5 * unit),
                .ellipse(centeredAt: upperRight, radius: 3.5 * unit),
                .ellipse(centeredAt: lowerRight, radius: 3.5 * unit),
            ]
        case .records:
            let record = CGRect(
                x: x + 5 * unit,
                y: y + unit,
                width: w - 10 * unit,
                height: h - 3 * unit
            )
            return [
                .ellipse(in: CGRect(x: record.minX, y: record.minY, width: record.width, height: 8 * unit)),
                .line(
                    from: CGPoint(x: record.minX, y: record.minY + 4 * unit),
                    to: CGPoint(x: record.minX, y: record.maxY - 4 * unit)
                ),
                .line(
                    from: CGPoint(x: record.maxX, y: record.minY + 4 * unit),
                    to: CGPoint(x: record.maxX, y: record.maxY - 4 * unit)
                ),
                .ellipse(in: CGRect(x: record.minX, y: record.maxY - 8 * unit, width: record.width, height: 8 * unit)),
            ]
        case .messageQueue:
            return [0.18, 0.5, 0.82].map { fraction in
                .roundedRectangle(
                    CGRect(
                        x: x + 3 * unit,
                        y: y + h * fraction - 3 * unit,
                        width: w - 6 * unit,
                        height: 6 * unit
                    ),
                    radius: 3 * unit
                )
            }
        case .archive:
            let tray = CGRect(
                x: x + 4 * unit,
                y: y + 5 * unit,
                width: w - 8 * unit,
                height: h - 10 * unit
            )
            return [
                .roundedRectangle(tray, radius: 3 * unit),
                .line(
                    from: CGPoint(x: tray.minX, y: tray.minY + 6 * unit),
                    to: CGPoint(x: tray.maxX, y: tray.minY + 6 * unit)
                ),
                .line(
                    from: CGPoint(x: icon.midX - 5 * unit, y: tray.minY + 10 * unit),
                    to: CGPoint(x: icon.midX + 5 * unit, y: tray.minY + 10 * unit)
                ),
            ]
        }
    }

    func labelRect(in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + 10,
            y: rect.minY + rect.height * 0.54,
            width: max(1, rect.width - 20),
            height: max(1, rect.height * 0.38)
        )
    }

    private func pictogramRect(in rect: CGRect) -> CGRect {
        let horizontalInset = min(8, max(1, rect.width * 0.08))
        let verticalInset = min(8, max(1, rect.height * 0.08))
        let availableWidth = max(1, rect.width - horizontalInset * 2)
        let availableHeight = max(1, rect.height - verticalInset * 2)
        let width = min(availableWidth, min(40, max(28, rect.width * 0.25)))
        let height = min(availableHeight, min(28, max(22, rect.height * 0.30)))
        let preferredTop = rect.minY + max(14, rect.height * 0.16)
        return CGRect(
            x: rect.midX - width / 2,
            y: min(
                max(rect.minY + verticalInset, preferredTop),
                rect.maxY - verticalInset - height
            ),
            width: width,
            height: height
        )
    }
}

struct BoardConnectorAnchorPair: Equatable {
    let start: BoardPoint
    let end: BoardPoint
}

enum BoardConnectorSide: String, Equatable {
    case left
    case right
    case top
    case bottom
}

struct BoardConnectorNormalizedAnchor: Equatable {
    let side: BoardConnectorSide
    let offset: Double

    func point(in frame: BoardRect) -> BoardPoint {
        let boundedOffset = min(1, max(0, offset))
        switch side {
        case .left:
            return BoardPoint(
                x: frame.origin.x,
                y: frame.origin.y + frame.size.height * boundedOffset
            )
        case .right:
            return BoardPoint(
                x: frame.origin.x + frame.size.width,
                y: frame.origin.y + frame.size.height * boundedOffset
            )
        case .top:
            return BoardPoint(
                x: frame.origin.x + frame.size.width * boundedOffset,
                y: frame.origin.y
            )
        case .bottom:
            return BoardPoint(
                x: frame.origin.x + frame.size.width * boundedOffset,
                y: frame.origin.y + frame.size.height
            )
        }
    }
}

enum BoardConnectorAnchorLayout {
    static func usesAutomaticPair(
        start: BoardPoint,
        end: BoardPoint,
        source: BoardBox,
        target: BoardBox
    ) -> Bool {
        let automatic = between(source: source, target: target)
        return pointsMatch(start, automatic.start)
            && pointsMatch(end, automatic.end)
    }

    static func between(
        source: BoardBox,
        target: BoardBox
    ) -> BoardConnectorAnchorPair {
        let sourceCenter = center(of: source.frame)
        let targetCenter = center(of: target.frame)
        let horizontal = abs(targetCenter.x - sourceCenter.x)
            >= abs(targetCenter.y - sourceCenter.y)

        if horizontal {
            if targetCenter.x >= sourceCenter.x {
                return BoardConnectorAnchorPair(
                    start: rightCenter(of: source.frame),
                    end: leftCenter(of: target.frame)
                )
            }
            return BoardConnectorAnchorPair(
                start: leftCenter(of: source.frame),
                end: rightCenter(of: target.frame)
            )
        }
        if targetCenter.y >= sourceCenter.y {
            return BoardConnectorAnchorPair(
                start: bottomCenter(of: source.frame),
                end: topCenter(of: target.frame)
            )
        }
        return BoardConnectorAnchorPair(
            start: topCenter(of: source.frame),
            end: bottomCenter(of: target.frame)
        )
    }

    static func anchor(on box: BoardBox, toward point: BoardPoint) -> BoardPoint {
        let center = center(of: box.frame)
        let horizontal = abs(point.x - center.x) >= abs(point.y - center.y)
        if horizontal {
            return point.x >= center.x
                ? rightCenter(of: box.frame)
                : leftCenter(of: box.frame)
        }
        return point.y >= center.y
            ? bottomCenter(of: box.frame)
            : topCenter(of: box.frame)
    }

    static func normalizedAnchor(
        for point: BoardPoint,
        on box: BoardBox
    ) -> BoardConnectorNormalizedAnchor {
        let frame = box.frame
        let minX = frame.origin.x
        let maxX = frame.origin.x + frame.size.width
        let minY = frame.origin.y
        let maxY = frame.origin.y + frame.size.height
        let candidates: [(BoardConnectorSide, Double)] = [
            (.left, abs(point.x - minX)),
            (.right, abs(point.x - maxX)),
            (.top, abs(point.y - minY)),
            (.bottom, abs(point.y - maxY)),
        ]
        let side = candidates.min { lhs, rhs in
            lhs.1 < rhs.1
        }?.0 ?? .right
        let offset: Double
        switch side {
        case .left, .right:
            offset = frame.size.height > 0
                ? (point.y - minY) / frame.size.height
                : 0.5
        case .top, .bottom:
            offset = frame.size.width > 0
                ? (point.x - minX) / frame.size.width
                : 0.5
        }
        return BoardConnectorNormalizedAnchor(
            side: side,
            offset: min(1, max(0, offset))
        )
    }

    private static func center(of frame: BoardRect) -> BoardPoint {
        BoardPoint(
            x: frame.origin.x + frame.size.width / 2,
            y: frame.origin.y + frame.size.height / 2
        )
    }

    private static func leftCenter(of frame: BoardRect) -> BoardPoint {
        BoardPoint(
            x: frame.origin.x,
            y: frame.origin.y + frame.size.height / 2
        )
    }

    private static func rightCenter(of frame: BoardRect) -> BoardPoint {
        BoardPoint(
            x: frame.origin.x + frame.size.width,
            y: frame.origin.y + frame.size.height / 2
        )
    }

    private static func topCenter(of frame: BoardRect) -> BoardPoint {
        BoardPoint(
            x: frame.origin.x + frame.size.width / 2,
            y: frame.origin.y
        )
    }

    private static func bottomCenter(of frame: BoardRect) -> BoardPoint {
        BoardPoint(
            x: frame.origin.x + frame.size.width / 2,
            y: frame.origin.y + frame.size.height
        )
    }

    private static func pointsMatch(
        _ lhs: BoardPoint,
        _ rhs: BoardPoint
    ) -> Bool {
        abs(lhs.x - rhs.x) < 0.000_001
            && abs(lhs.y - rhs.y) < 0.000_001
    }
}

struct BoardNodeLabelLayout: Equatable {
    static let fontSize = 13.0
    static let lineHeight = 15.0
    static let estimatedCharacterWidth = 7.0
    static let maximumLineCount = 3

    let rect: CGRect
    let lines: [String]

    init(text: String, in rect: CGRect) {
        self.rect = rect
        let characterLimit = max(
            1,
            Int(floor(rect.width / Self.estimatedCharacterWidth))
        )
        let lineLimit = max(
            1,
            min(
                Self.maximumLineCount,
                Int(floor(rect.height / Self.lineHeight))
            )
        )
        let wrapped = Self.wrap(text, characterLimit: characterLimit)
        if wrapped.count <= lineLimit {
            lines = wrapped
        } else {
            var visible = Array(wrapped.prefix(lineLimit))
            visible[lineLimit - 1] = Self.ellipsize(
                visible[lineLimit - 1],
                characterLimit: characterLimit
            )
            lines = visible
        }
    }

    func lineRect(at index: Int) -> CGRect {
        let contentHeight = Double(lines.count) * Self.lineHeight
        return CGRect(
            x: rect.minX,
            y: rect.midY - contentHeight / 2
                + Double(index) * Self.lineHeight,
            width: rect.width,
            height: Self.lineHeight
        )
    }

    func baselineY(at index: Int) -> Double {
        lineRect(at: index).minY + 12
    }

    var drawIOValue: String {
        lines.joined(separator: "\n")
    }

    private static func wrap(
        _ text: String,
        characterLimit: Int
    ) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [""] }
        var result: [String] = []
        var current = ""

        for word in words {
            if word.count > characterLimit {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                var remaining = word
                while remaining.count > characterLimit {
                    let boundary = remaining.index(
                        remaining.startIndex,
                        offsetBy: characterLimit
                    )
                    result.append(String(remaining[..<boundary]))
                    remaining = String(remaining[boundary...])
                }
                current = remaining
                continue
            }

            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count <= characterLimit {
                current = candidate
            } else {
                result.append(current)
                current = word
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [""] : result
    }

    private static func ellipsize(
        _ value: String,
        characterLimit: Int
    ) -> String {
        guard characterLimit > 1 else { return "…" }
        return String(value.prefix(characterLimit - 1)) + "…"
    }
}

enum BoardRenderLayer: Int, CaseIterable {
    case connector
    case stroke
    case label
    case box
}

enum BoardRenderOrder {
    static func elements(in document: BoardDocument) -> [BoardElement] {
        elements(document.elements)
    }

    static func elements(_ elements: [BoardElement]) -> [BoardElement] {
        elements.enumerated().sorted { lhs, rhs in
            let leftLayer = layer(for: lhs.element).rawValue
            let rightLayer = layer(for: rhs.element).rawValue
            return leftLayer == rightLayer
                ? lhs.offset < rhs.offset
                : leftLayer < rightLayer
        }.map { $0.element }
    }

    static func layer(for element: BoardElement) -> BoardRenderLayer {
        switch element {
        case .connector: .connector
        case .stroke: .stroke
        case .label: .label
        case .box: .box
        }
    }
}

struct BoardOrthogonalConnectorRoute: Equatable {
    let points: [BoardPoint]

    init(start: BoardPoint, end: BoardPoint) {
        if start.x == end.x || start.y == end.y {
            points = [start, end]
        } else if abs(end.x - start.x) >= abs(end.y - start.y) {
            let middleX = (start.x + end.x) / 2
            points = [
                start,
                BoardPoint(x: middleX, y: start.y),
                BoardPoint(x: middleX, y: end.y),
                end,
            ]
        } else {
            let middleY = (start.y + end.y) / 2
            points = [
                start,
                BoardPoint(x: start.x, y: middleY),
                BoardPoint(x: end.x, y: middleY),
                end,
            ]
        }
    }
}

struct BoardVectorPath: Equatable {
    enum Command: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(control1: CGPoint, control2: CGPoint, end: CGPoint)
        case close
    }

    let commands: [Command]

    var cgPath: CGPath {
        let path = CGMutablePath()
        for command in commands {
            switch command {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .curve(let control1, let control2, let end):
                path.addCurve(to: end, control1: control1, control2: control2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    var svgPathData: String {
        commands.map { command in
            switch command {
            case .move(let point):
                "M \(Self.number(point.x)) \(Self.number(point.y))"
            case .line(let point):
                "L \(Self.number(point.x)) \(Self.number(point.y))"
            case .curve(let control1, let control2, let end):
                "C \(Self.number(control1.x)) \(Self.number(control1.y)) \(Self.number(control2.x)) \(Self.number(control2.y)) \(Self.number(end.x)) \(Self.number(end.y))"
            case .close:
                "Z"
            }
        }.joined(separator: " ")
    }

    static func line(from start: CGPoint, to end: CGPoint) -> BoardVectorPath {
        BoardVectorPath(commands: [.move(start), .line(end)])
    }

    static func roundedRectangle(_ rect: CGRect, radius: CGFloat) -> BoardVectorPath {
        let radius = min(max(0, radius), min(rect.width, rect.height) / 2)
        let control = radius * 0.552_284_749_8
        return BoardVectorPath(commands: [
            .move(CGPoint(x: rect.minX + radius, y: rect.minY)),
            .line(CGPoint(x: rect.maxX - radius, y: rect.minY)),
            .curve(
                control1: CGPoint(x: rect.maxX - radius + control, y: rect.minY),
                control2: CGPoint(x: rect.maxX, y: rect.minY + radius - control),
                end: CGPoint(x: rect.maxX, y: rect.minY + radius)
            ),
            .line(CGPoint(x: rect.maxX, y: rect.maxY - radius)),
            .curve(
                control1: CGPoint(x: rect.maxX, y: rect.maxY - radius + control),
                control2: CGPoint(x: rect.maxX - radius + control, y: rect.maxY),
                end: CGPoint(x: rect.maxX - radius, y: rect.maxY)
            ),
            .line(CGPoint(x: rect.minX + radius, y: rect.maxY)),
            .curve(
                control1: CGPoint(x: rect.minX + radius - control, y: rect.maxY),
                control2: CGPoint(x: rect.minX, y: rect.maxY - radius + control),
                end: CGPoint(x: rect.minX, y: rect.maxY - radius)
            ),
            .line(CGPoint(x: rect.minX, y: rect.minY + radius)),
            .curve(
                control1: CGPoint(x: rect.minX, y: rect.minY + radius - control),
                control2: CGPoint(x: rect.minX + radius - control, y: rect.minY),
                end: CGPoint(x: rect.minX + radius, y: rect.minY)
            ),
            .close,
        ])
    }

    static func ellipse(in rect: CGRect) -> BoardVectorPath {
        let control = 0.552_284_749_8
        let dx = rect.width / 2 * control
        let dy = rect.height / 2 * control
        return BoardVectorPath(commands: [
            .move(CGPoint(x: rect.midX, y: rect.minY)),
            .curve(
                control1: CGPoint(x: rect.midX + dx, y: rect.minY),
                control2: CGPoint(x: rect.maxX, y: rect.midY - dy),
                end: CGPoint(x: rect.maxX, y: rect.midY)
            ),
            .curve(
                control1: CGPoint(x: rect.maxX, y: rect.midY + dy),
                control2: CGPoint(x: rect.midX + dx, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.maxY)
            ),
            .curve(
                control1: CGPoint(x: rect.midX - dx, y: rect.maxY),
                control2: CGPoint(x: rect.minX, y: rect.midY + dy),
                end: CGPoint(x: rect.minX, y: rect.midY)
            ),
            .curve(
                control1: CGPoint(x: rect.minX, y: rect.midY - dy),
                control2: CGPoint(x: rect.midX - dx, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.minY)
            ),
            .close,
        ])
    }

    static func ellipse(centeredAt center: CGPoint, radius: CGFloat) -> BoardVectorPath {
        ellipse(
            in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
    }

    static func number(_ value: CGFloat) -> String {
        var formatted = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(value)
        )
        while formatted.contains(".") && formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." { formatted.removeLast() }
        return formatted == "-0" ? "0" : formatted
    }
}
