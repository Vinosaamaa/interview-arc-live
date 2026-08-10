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
        let widthValue = settings.viewport.width * settings.scale
        let heightValue = settings.viewport.height * settings.scale
        guard widthValue.isFinite, heightValue.isFinite,
              widthValue > 0, heightValue > 0,
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
        let svg = Data(svg(document, settings: settings).utf8)
        let png = try png(
            document,
            settings: settings,
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
        settings: BoardExportSettings
    ) -> String {
        let width = number(settings.viewport.width)
        let height = number(settings.viewport.height)
        var rows = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\" role=\"img\" aria-label=\"System design board\">",
            "  <rect x=\"0\" y=\"0\" width=\"\(width)\" height=\"\(height)\" fill=\"#\(attribute(settings.background.hexRGB))\"/>",
        ]

        for element in document.elements {
            switch element {
            case .box(let box):
                let centerX = box.frame.origin.x + box.frame.size.width / 2
                let centerY = box.frame.origin.y + box.frame.size.height / 2
                rows.append(
                    "  <g data-id=\"\(attribute(box.id.rawValue))\" data-node-kind=\"\(attribute(box.kind.rawValue))\"><rect x=\"\(number(box.frame.origin.x))\" y=\"\(number(box.frame.origin.y))\" width=\"\(number(box.frame.size.width))\" height=\"\(number(box.frame.size.height))\" rx=\"11\" fill=\"#\(attribute(box.fill.hexRGB))\" stroke=\"#\(attribute(box.stroke.hexRGB))\" stroke-width=\"1.5\"/><rect x=\"\(number(centerX - 20))\" y=\"\(number(centerY - 25))\" width=\"40\" height=\"22\" rx=\"6\" fill=\"none\" stroke=\"#\(attribute(box.stroke.hexRGB))\" stroke-width=\"1.5\"/><text x=\"\(number(centerX))\" y=\"\(number(centerY - 10))\" text-anchor=\"middle\" font-family=\"ui-monospace, monospace\" font-size=\"9\" font-weight=\"700\" fill=\"#\(attribute(box.stroke.hexRGB))\">\(text(box.kind.glyphToken))</text><text x=\"\(number(centerX))\" y=\"\(number(centerY + 20))\" text-anchor=\"middle\" font-family=\"-apple-system, BlinkMacSystemFont, sans-serif\" font-size=\"13\" font-weight=\"600\" fill=\"#\(attribute(box.stroke.hexRGB))\">\(text(box.label))</text></g>"
                )
            case .connector(let connector):
                let midpoint = BoardPoint(
                    x: (connector.start.point.x + connector.end.point.x) / 2,
                    y: (connector.start.point.y + connector.end.point.y) / 2
                )
                let arrow = arrowWingPoints(
                    from: connector.start.point,
                    to: connector.end.point
                )
                rows.append(
                    "  <g data-id=\"\(attribute(connector.id.rawValue))\"><path d=\"M \(number(connector.start.point.x)) \(number(connector.start.point.y)) L \(number(connector.end.point.x)) \(number(connector.end.point.y))\" fill=\"none\" stroke=\"#\(attribute(connector.stroke.hexRGB))\" stroke-width=\"1.7\" stroke-linecap=\"round\"/><polygon points=\"\(number(connector.end.point.x)),\(number(connector.end.point.y)) \(number(arrow.0.x)),\(number(arrow.0.y)) \(number(arrow.1.x)),\(number(arrow.1.y))\" fill=\"#\(attribute(connector.stroke.hexRGB))\"/>\(connector.label.isEmpty ? "" : "<text x=\"\(number(midpoint.x))\" y=\"\(number(midpoint.y - 7))\" text-anchor=\"middle\" font-family=\"-apple-system, BlinkMacSystemFont, sans-serif\" font-size=\"12\" fill=\"#667A76\">\(text(connector.label))</text>")</g>"
                )
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

    private func png(
        _ document: BoardDocument,
        settings: BoardExportSettings,
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
                width: settings.viewport.width,
                height: settings.viewport.height
            )
        )

        for element in document.elements {
            draw(
                element,
                in: context,
                viewportHeight: settings.viewport.height
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
            let rect = CGRect(
                x: box.frame.origin.x,
                y: viewportHeight - box.frame.origin.y - box.frame.size.height,
                width: box.frame.size.width,
                height: box.frame.size.height
            )
            context.setFillColor((try? rgb(box.fill).cgColor) ?? NSColor.white.cgColor)
            context.setStrokeColor((try? rgb(box.stroke).cgColor) ?? NSColor.gray.cgColor)
            context.setLineWidth(1.5)
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: 11,
                cornerHeight: 11,
                transform: nil
            )
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            let glyphRect = CGRect(
                x: rect.midX - 20,
                y: rect.midY + 3,
                width: 40,
                height: 22
            )
            context.addPath(
                CGPath(
                    roundedRect: glyphRect,
                    cornerWidth: 6,
                    cornerHeight: 6,
                    transform: nil
                )
            )
            context.strokePath()
            drawText(
                box.kind.glyphToken,
                in: glyphRect.insetBy(dx: 2, dy: 5),
                size: 9,
                weight: .bold,
                color: (try? rgb(box.stroke).nsColor) ?? NSColor.gray,
                alignment: .center,
                fontDesign: .monospaced
            )
            drawText(
                box.label,
                in: CGRect(
                    x: rect.minX + 10,
                    y: rect.midY - 26,
                    width: rect.width - 20,
                    height: 22
                ),
                size: 13,
                weight: .semibold,
                color: (try? rgb(box.stroke).nsColor) ?? NSColor.gray,
                alignment: .center
            )

        case .connector(let connector):
            let start = cgPoint(connector.start.point, viewportHeight: viewportHeight)
            let end = cgPoint(connector.end.point, viewportHeight: viewportHeight)
            let color = (try? rgb(connector.stroke).cgColor) ?? NSColor.gray.cgColor
            context.setStrokeColor(color)
            context.setFillColor(color)
            context.setLineWidth(1.7)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            drawArrow(from: start, to: end, in: context)
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
                    color: NSColor(red: 102 / 255, green: 122 / 255, blue: 118 / 255, alpha: 1),
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
        fontDesign: NSFontDescriptor.SystemDesign = .default
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
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
