import AppKit
import Foundation
import InterviewArcLiveCore

enum DeterministicBoardRendererError: Error, Equatable, Sendable {
    case invalidDimensions
    case pixelBudgetExceeded
    case unsupportedBackground
    case bitmapCreationFailed
    case pngEncodingFailed
}

struct RenderedBoardArtifacts: Equatable, Sendable {
    let canonicalSource: Data
    let svg: Data
    let png: Data
    let pngWidth: Int
    let pngHeight: Int
}

/// Deterministically renders one validated BoardDocument without interpreting
/// labels as HTML or resolving any external resource.
struct DeterministicBoardRenderer: Sendable {
    static let defaultMaximumPixelCount = 32_000_000

    let maximumPixelCount: Int
    let codec: DrawIOBoardCodec

    init(
        maximumPixelCount: Int = Self.defaultMaximumPixelCount,
        codec: DrawIOBoardCodec = DrawIOBoardCodec()
    ) {
        self.maximumPixelCount = max(1, maximumPixelCount)
        self.codec = codec
    }

    func render(
        _ document: BoardDocument,
        settings: BoardExportSettings
    ) throws -> RenderedBoardArtifacts {
        let frame = BoardRenderFrame(
            document: document,
            minimumViewport: settings.viewport
        )
        let widthValue = frame.width * settings.scale
        let heightValue = frame.height * settings.scale
        guard widthValue.isFinite, heightValue.isFinite,
              widthValue > 0, heightValue > 0,
              widthValue <= BoardExportSettings.maximumPixelDimension,
              heightValue <= BoardExportSettings.maximumPixelDimension,
              widthValue <= Double(Int.max), heightValue <= Double(Int.max) else {
            throw DeterministicBoardRendererError.invalidDimensions
        }
        let width = Int(widthValue.rounded())
        let height = Int(heightValue.rounded())
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= maximumPixelCount else {
            throw DeterministicBoardRendererError.pixelBudgetExceeded
        }
        let background = try rgb(settings.background)
        guard background.luminance >= 0.72 else {
            throw DeterministicBoardRendererError.unsupportedBackground
        }

        let canonicalSource = Data(try codec.encode(document).utf8)
        let svg = Data(svg(document, settings: settings, frame: frame).utf8)
        let png = try png(
            document,
            settings: settings,
            frame: frame,
            pixelWidth: width,
            pixelHeight: height,
            background: background
        )
        return RenderedBoardArtifacts(
            canonicalSource: canonicalSource,
            svg: svg,
            png: png,
            pngWidth: width,
            pngHeight: height
        )
    }

    private func svg(
        _ document: BoardDocument,
        settings: BoardExportSettings,
        frame: BoardRenderFrame
    ) -> String {
        let originX = number(frame.minX)
        let originY = number(frame.minY)
        let width = number(frame.width)
        let height = number(frame.height)
        var rows = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"\(originX) \(originY) \(width) \(height)\" role=\"img\" aria-label=\"System design board\">",
            "  <rect x=\"\(originX)\" y=\"\(originY)\" width=\"\(width)\" height=\"\(height)\" fill=\"#\(attribute(settings.background.hexRGB))\"/>",
        ]

        for (renderIndex, element) in BoardRenderOrder.elements(
            in: document
        ).enumerated() {
            switch element {
            case .box(let box):
                let visual = box.kind.visual
                let rect = CGRect(
                    x: box.frame.origin.x,
                    y: box.frame.origin.y,
                    width: box.frame.size.width,
                    height: box.frame.size.height
                )
                let labelRect = visual.labelRect(in: rect)
                let labelLayout = BoardNodeLabelLayout(
                    text: box.label,
                    in: labelRect
                )
                let strokeWidth = number(visual.strokeWidth(in: rect))
                let clipID = "ia-node-label-\(renderIndex)"
                var nodeRows = [
                    "  <g data-id=\"\(attribute(box.id.rawValue))\" data-node-kind=\"\(attribute(box.kind.rawValue))\" data-node-visual=\"\(attribute(visual.stableKey))\">",
                    "    <path d=\"\(attribute(visual.outlinePath(in: rect).svgPathData))\" fill=\"#\(attribute(box.fill.hexRGB))\" stroke=\"#\(attribute(box.stroke.hexRGB))\" stroke-width=\"\(strokeWidth)\" stroke-linejoin=\"round\"/>",
                    "    <clipPath id=\"\(clipID)\"><rect x=\"\(number(labelRect.minX))\" y=\"\(number(labelRect.minY))\" width=\"\(number(labelRect.width))\" height=\"\(number(labelRect.height))\"/></clipPath>",
                ]
                for path in visual.detailPaths(in: rect) + visual.pictogramPaths(in: rect) {
                    nodeRows.append(
                        "    <path d=\"\(attribute(path.svgPathData))\" fill=\"none\" stroke=\"#\(attribute(box.stroke.hexRGB))\" stroke-width=\"\(strokeWidth)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
                    )
                }
                nodeRows.append(
                    "    <text data-label-layout=\"wrapped-v1\" clip-path=\"url(#\(clipID))\" text-anchor=\"middle\" font-family=\"-apple-system, BlinkMacSystemFont, sans-serif\" font-size=\"\(number(labelLayout.resolvedFontSize))\" font-weight=\"600\" fill=\"#\(attribute(box.stroke.hexRGB))\">"
                )
                for (index, line) in labelLayout.lines.enumerated() {
                    nodeRows.append(
                        "      <tspan x=\"\(number(labelRect.midX))\" y=\"\(number(labelLayout.baselineY(at: index)))\">\(text(line))</tspan>"
                    )
                }
                nodeRows.append("    </text>")
                nodeRows.append("  </g>")
                rows.append(contentsOf: nodeRows)
            case .connector(let connector):
                rows.append(contentsOf: svgConnectorRows(connector))
            case .label(let label):
                rows.append(
                    "  <text data-id=\"\(attribute(label.id.rawValue))\" x=\"\(number(label.origin.x))\" y=\"\(number(label.origin.y + 16))\" font-family=\"-apple-system, BlinkMacSystemFont, sans-serif\" font-size=\"16\" font-weight=\"600\" fill=\"#\(attribute(label.color.hexRGB))\">\(text(label.text))</text>"
                )
            case .stroke(let stroke):
                let points = stroke.points.map {
                    "\(number($0.x)),\(number($0.y))"
                }.joined(separator: " ")
                rows.append(
                    "  <polyline data-id=\"\(attribute(stroke.id.rawValue))\" points=\"\(points)\" fill=\"none\" stroke=\"#\(attribute(stroke.color.hexRGB))\" stroke-width=\"\(number(stroke.width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
                )
            }
        }
        rows.append("</svg>")
        return rows.joined(separator: "\n") + "\n"
    }

    private func svgConnectorRows(_ connector: BoardConnector) -> [String] {
        let route = BoardOrthogonalConnectorRoute(
            start: connector.start.point,
            end: connector.end.point
        )
        let routeData = route.points.enumerated().map { index, point in
            "\(index == 0 ? "M" : "L") \(number(point.x)) \(number(point.y))"
        }.joined(separator: " ")
        let arrowStart = route.points.dropLast().last ?? connector.start.point
        let arrow = arrowWingPoints(
            from: arrowStart,
            to: connector.end.point
        )
        let color = attribute(connector.stroke.hexRGB)
        var rows = [
            "  <g data-id=\"\(attribute(connector.id.rawValue))\" data-element-kind=\"connector\">",
            "    <path data-role=\"route\" d=\"\(routeData)\" fill=\"none\" stroke=\"#\(color)\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>",
            "    <polygon data-role=\"arrow\" points=\"\(number(connector.end.point.x)),\(number(connector.end.point.y)) \(number(arrow.0.x)),\(number(arrow.0.y)) \(number(arrow.1.x)),\(number(arrow.1.y))\" fill=\"#\(color)\"/>",
        ]
        if !connector.label.isEmpty {
            let midpoint = BoardPoint(
                x: (connector.start.point.x + connector.end.point.x) / 2,
                y: (connector.start.point.y + connector.end.point.y) / 2
            )
            rows.append(
                "    <text data-role=\"label\" x=\"\(number(midpoint.x))\" y=\"\(number(midpoint.y - 7))\" text-anchor=\"middle\" font-family=\"-apple-system, BlinkMacSystemFont, sans-serif\" font-size=\"12\" fill=\"#52628B\">\(text(connector.label))</text>"
            )
        }
        rows.append("  </g>")
        return rows
    }

    private func png(
        _ document: BoardDocument,
        settings: BoardExportSettings,
        frame: BoardRenderFrame,
        pixelWidth: Int,
        pixelHeight: Int,
        background: RGB
    ) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelWidth * 4,
            bitsPerPixel: 32
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw DeterministicBoardRendererError.bitmapCreationFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .none
        context.scaleBy(x: settings.scale, y: settings.scale)
        context.setFillColor(background.cgColor)
        context.fill(
            CGRect(
                x: 0,
                y: 0,
                width: frame.width,
                height: frame.height
            )
        )
        context.translateBy(x: -frame.minX, y: 0)

        for element in BoardRenderOrder.elements(in: document) {
            draw(
                element,
                in: context,
                viewportHeight: frame.maxY
            )
        }
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DeterministicBoardRendererError.pngEncodingFailed
        }
        return data
    }

    private func draw(
        _ element: BoardElement,
        in context: CGContext,
        viewportHeight: Double
    ) {
        switch element {
        case .box(let box):
            let boardRect = CGRect(
                x: box.frame.origin.x,
                y: box.frame.origin.y,
                width: box.frame.size.width,
                height: box.frame.size.height
            )
            let visual = box.kind.visual
            let stroke = (try? rgb(box.stroke).cgColor) ?? NSColor.gray.cgColor

            context.saveGState()
            context.translateBy(x: 0, y: viewportHeight)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor((try? rgb(box.fill).cgColor) ?? NSColor.white.cgColor)
            context.setStrokeColor(stroke)
            context.setLineWidth(visual.strokeWidth(in: boardRect))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(visual.outlinePath(in: boardRect).cgPath)
            context.drawPath(using: .fillStroke)
            context.beginPath()
            for path in visual.detailPaths(in: boardRect) + visual.pictogramPaths(in: boardRect) {
                context.addPath(path.cgPath)
            }
            context.strokePath()
            context.restoreGState()

            let labelLayout = BoardNodeLabelLayout(
                text: box.label,
                in: visual.labelRect(in: boardRect)
            )
            let labelClip = CGRect(
                x: labelLayout.rect.minX,
                y: viewportHeight - labelLayout.rect.maxY,
                width: labelLayout.rect.width,
                height: labelLayout.rect.height
            )
            context.saveGState()
            context.clip(to: labelClip)
            for (index, line) in labelLayout.lines.enumerated() {
                let lineRect = labelLayout.lineRect(at: index)
                drawText(
                    line,
                    in: CGRect(
                        x: lineRect.minX,
                        y: viewportHeight - lineRect.maxY,
                        width: lineRect.width,
                        height: lineRect.height
                    ),
                    size: labelLayout.resolvedFontSize,
                    weight: .semibold,
                    color: (try? rgb(box.stroke).nsColor) ?? NSColor.gray,
                    alignment: .center,
                    lineBreakMode: .byClipping
                )
            }
            context.restoreGState()

        case .connector(let connector):
            let route = BoardOrthogonalConnectorRoute(
                start: connector.start.point,
                end: connector.end.point
            )
            let points = route.points.map {
                cgPoint($0, viewportHeight: viewportHeight)
            }
            guard let start = points.first, let end = points.last else { return }
            let color = (try? rgb(connector.stroke).cgColor) ?? NSColor.gray.cgColor
            context.setStrokeColor(color)
            context.setFillColor(color)
            context.setLineWidth(1.7)
            context.move(to: start)
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
            drawArrow(from: points.dropLast().last ?? start, to: end, in: context)
            if !connector.label.isEmpty {
                drawText(
                    connector.label,
                    in: CGRect(
                        x: (start.x + end.x) / 2 - 90,
                        y: (start.y + end.y) / 2 + 5,
                        width: 180,
                        height: 20
                    ),
                    size: 12,
                    weight: .regular,
                    color: NSColor(red: 82 / 255, green: 98 / 255, blue: 139 / 255, alpha: 1),
                    alignment: .center
                )
            }

        case .label(let label):
            drawText(
                label.text,
                in: CGRect(
                    x: label.origin.x,
                    y: viewportHeight - label.origin.y - 24,
                    width: 240,
                    height: 24
                ),
                size: 16,
                weight: .semibold,
                color: (try? rgb(label.color).nsColor) ?? NSColor.black,
                alignment: .left
            )

        case .stroke(let stroke):
            guard let first = stroke.points.first else { return }
            context.setStrokeColor(
                (try? rgb(stroke.color).cgColor) ?? NSColor.gray.cgColor
            )
            context.setLineWidth(stroke.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: cgPoint(first, viewportHeight: viewportHeight))
            for point in stroke.points.dropFirst() {
                context.addLine(to: cgPoint(point, viewportHeight: viewportHeight))
            }
            context.strokePath()
        }
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment,
        fontDesign: NSFontDescriptor.SystemDesign = .default,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight)
                    .fontDescriptor.withDesign(fontDesign)
                    .flatMap { NSFont(descriptor: $0, size: size) }
                    ?? NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 10
        let wing: CGFloat = 0.5
        let first = CGPoint(
            x: end.x - length * cos(angle - wing),
            y: end.y - length * sin(angle - wing)
        )
        let second = CGPoint(
            x: end.x - length * cos(angle + wing),
            y: end.y - length * sin(angle + wing)
        )
        context.move(to: end)
        context.addLine(to: first)
        context.addLine(to: second)
        context.closePath()
        context.fillPath()
    }

    private func arrowWingPoints(
        from start: BoardPoint,
        to end: BoardPoint
    ) -> (BoardPoint, BoardPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = 10.0
        let wing = 0.5
        return (
            BoardPoint(
                x: end.x - length * cos(angle - wing),
                y: end.y - length * sin(angle - wing)
            ),
            BoardPoint(
                x: end.x - length * cos(angle + wing),
                y: end.y - length * sin(angle + wing)
            )
        )
    }

    private func cgPoint(_ point: BoardPoint, viewportHeight: Double) -> CGPoint {
        CGPoint(x: point.x, y: viewportHeight - point.y)
    }

    private func rgb(_ color: BoardColor) throws -> RGB {
        let value = color.hexRGB
        guard value.count == 6,
              let packed = UInt32(value, radix: 16) else {
            throw DeterministicBoardRendererError.unsupportedBackground
        }
        return RGB(
            red: CGFloat((packed >> 16) & 0xff) / 255,
            green: CGFloat((packed >> 8) & 0xff) / 255,
            blue: CGFloat(packed & 0xff) / 255
        )
    }

    private func attribute(_ value: String) -> String {
        text(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func text(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func number(_ value: Double) -> String {
        var formatted = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        while formatted.contains(".") && formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." { formatted.removeLast() }
        return formatted == "-0" ? "0" : formatted
    }
}

private struct BoardRenderFrame {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }

    init(document: BoardDocument, minimumViewport: BoardSize) {
        var bounds = CGRect(
            x: 0,
            y: 0,
            width: minimumViewport.width,
            height: minimumViewport.height
        )
        for element in document.elements {
            let elementBounds: CGRect
            switch element {
            case .box(let box):
                let rect = CGRect(
                    x: box.frame.origin.x,
                    y: box.frame.origin.y,
                    width: box.frame.size.width,
                    height: box.frame.size.height
                )
                let inset = box.kind.visual.strokeWidth(in: rect) / 2
                elementBounds = rect.insetBy(dx: -inset, dy: -inset)

            case .connector(let connector):
                let points = BoardOrthogonalConnectorRoute(
                    start: connector.start.point,
                    end: connector.end.point
                ).points
                elementBounds = Self.bounds(of: points).insetBy(dx: -12, dy: -12)

            case .label(let label):
                elementBounds = CGRect(
                    x: label.origin.x,
                    y: label.origin.y,
                    width: BoardElementLayout.labelSize.width,
                    height: BoardElementLayout.labelSize.height
                )

            case .stroke(let stroke):
                elementBounds = Self.bounds(of: stroke.points).insetBy(
                    dx: -stroke.width / 2,
                    dy: -stroke.width / 2
                )
            }
            bounds = bounds.union(elementBounds)
        }
        minX = bounds.minX
        minY = bounds.minY
        maxX = bounds.maxX
        maxY = bounds.maxY
    }

    private static func bounds(of points: [BoardPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }
}

private struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: 1)
    }

    var cgColor: CGColor { nsColor.cgColor }

    var luminance: Double {
        0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
    }
}
