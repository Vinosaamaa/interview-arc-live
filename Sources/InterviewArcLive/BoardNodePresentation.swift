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
        switch pictogram {
        case .componentGrid:
            let side = min(8, h * 0.32)
            return [
                .roundedRectangle(CGRect(x: x + 4, y: y + 3, width: side, height: side), radius: 2),
                .roundedRectangle(CGRect(x: icon.maxX - side - 4, y: y + 3, width: side, height: side), radius: 2),
                .roundedRectangle(CGRect(x: x + 4, y: icon.maxY - side - 3, width: side, height: side), radius: 2),
                .roundedRectangle(CGRect(x: icon.maxX - side - 4, y: icon.maxY - side - 3, width: side, height: side), radius: 2),
            ]
        case .globe:
            let globe = CGRect(x: x + 5, y: y + 1, width: w - 10, height: h - 2)
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
            let left = CGPoint(x: x + 5, y: y + 5)
            let upperRight = CGPoint(x: icon.maxX - 5, y: y + 4)
            let lowerRight = CGPoint(x: icon.maxX - 5, y: icon.maxY - 4)
            return [
                .line(from: center, to: left),
                .line(from: center, to: upperRight),
                .line(from: center, to: lowerRight),
                .ellipse(centeredAt: left, radius: 3.5),
                .ellipse(centeredAt: center, radius: 3.5),
                .ellipse(centeredAt: upperRight, radius: 3.5),
                .ellipse(centeredAt: lowerRight, radius: 3.5),
            ]
        case .records:
            let record = CGRect(x: x + 5, y: y + 1, width: w - 10, height: h - 3)
            return [
                .ellipse(in: CGRect(x: record.minX, y: record.minY, width: record.width, height: 8)),
                .line(
                    from: CGPoint(x: record.minX, y: record.minY + 4),
                    to: CGPoint(x: record.minX, y: record.maxY - 4)
                ),
                .line(
                    from: CGPoint(x: record.maxX, y: record.minY + 4),
                    to: CGPoint(x: record.maxX, y: record.maxY - 4)
                ),
                .ellipse(in: CGRect(x: record.minX, y: record.maxY - 8, width: record.width, height: 8)),
            ]
        case .messageQueue:
            return [0.18, 0.5, 0.82].map { fraction in
                .roundedRectangle(
                    CGRect(
                        x: x + 3,
                        y: y + h * fraction - 3,
                        width: w - 6,
                        height: 6
                    ),
                    radius: 3
                )
            }
        case .archive:
            let tray = CGRect(x: x + 4, y: y + 5, width: w - 8, height: h - 10)
            return [
                .roundedRectangle(tray, radius: 3),
                .line(
                    from: CGPoint(x: tray.minX, y: tray.minY + 6),
                    to: CGPoint(x: tray.maxX, y: tray.minY + 6)
                ),
                .line(
                    from: CGPoint(x: icon.midX - 5, y: tray.minY + 10),
                    to: CGPoint(x: icon.midX + 5, y: tray.minY + 10)
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

    func drawIOPictogramDataURI(
        canvasSize: CGSize,
        strokeHex: String
    ) -> String {
        let rect = CGRect(origin: .zero, size: canvasSize)
        let paths = pictogramPaths(in: rect).map {
            "<path d='\($0.svgPathData)' fill='none' stroke='#\(strokeHex)' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/>"
        }.joined()
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 \(BoardVectorPath.number(canvasSize.width)) \(BoardVectorPath.number(canvasSize.height))'>\(paths)</svg>"
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        return "data:image/svg+xml," + (svg.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) ?? "")
    }

    private func pictogramRect(in rect: CGRect) -> CGRect {
        let width = min(40, max(28, rect.width * 0.25))
        let height = min(28, max(22, rect.height * 0.30))
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.minY + max(14, rect.height * 0.16),
            width: width,
            height: height
        )
    }
}

struct BoardOrthogonalConnectorRoute: Equatable {
    let points: [BoardPoint]

    init(start: BoardPoint, end: BoardPoint) {
        if start.x == end.x || start.y == end.y {
            points = [start, end]
        } else {
            let middleX = (start.x + end.x) / 2
            points = [
                start,
                BoardPoint(x: middleX, y: start.y),
                BoardPoint(x: middleX, y: end.y),
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
