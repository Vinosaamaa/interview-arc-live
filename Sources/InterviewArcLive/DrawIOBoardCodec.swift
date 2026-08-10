import Foundation
import InterviewArcLiveCore

enum DrawIOBoardCodecError: Error, Equatable, Sendable {
    case sourceTooLarge
    case invalidEncoding
    case unsafeXML
    case malformedXML
    case unsupportedSchema
    case missingCanvas
    case invalidElement
}

/// A bounded, uncompressed mxGraph document. Draw.io can open and edit every
/// emitted cell; `iaKind` and `ia*` attributes preserve Live's stricter model.
struct DrawIOBoardCodec: Sendable {
    static let defaultMaximumSourceBytes = 2 * 1_024 * 1_024

    let maximumSourceBytes: Int

    init(maximumSourceBytes: Int = Self.defaultMaximumSourceBytes) {
        self.maximumSourceBytes = max(1, maximumSourceBytes)
    }

    func encode(_ document: BoardDocument) throws -> String {
        var source = ""
        var byteCount = 0

        func append(_ lines: [String]) throws {
            for line in lines {
                let lineByteCount = line.utf8.count + 1
                guard lineByteCount <= maximumSourceBytes - byteCount else {
                    throw DrawIOBoardCodecError.sourceTooLarge
                }
                source.append(line)
                source.append("\n")
                byteCount += lineByteCount
            }
        }

        try append([
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<mxfile host=\"Interview Arc Live\" version=\"board-v1\">",
            "  <diagram id=\"board-v1\" name=\"Board\">",
            "    <mxGraphModel grid=\"1\" gridSize=\"20\" page=\"0\" iaSchemaVersion=\"\(document.schemaVersion)\" pageWidth=\"\(number(document.canvas.size.width))\" pageHeight=\"\(number(document.canvas.size.height))\">",
            "      <root>",
            "        <mxCell id=\"0\"/>",
            "        <mxCell id=\"1\" parent=\"0\"/>",
        ])

        let elementCellIDs = makeElementCellIDs(document.elements)
        var reservedCellIDs = Set(elementCellIDs.values)
        reservedCellIDs.formUnion(["0", "1"])
        for (index, element) in document.elements.enumerated() {
            let visualCellID: String?
            if case .box = element {
                var candidate = "__ia_node_visual_\(index)"
                while reservedCellIDs.contains(candidate) {
                    candidate.append("_")
                }
                reservedCellIDs.insert(candidate)
                visualCellID = candidate
            } else {
                visualCellID = nil
            }
            try append(
                encode(
                    element,
                    cellID: elementCellIDs[element.id] ?? element.id.rawValue,
                    visualCellID: visualCellID,
                    elementCellIDs: elementCellIDs
                )
            )
        }

        try append([
            "      </root>",
            "    </mxGraphModel>",
            "  </diagram>",
            "</mxfile>",
        ])
        return source
    }

    func decode(_ source: String) throws -> BoardDocument {
        guard let data = source.data(using: .utf8) else {
            throw DrawIOBoardCodecError.invalidEncoding
        }
        guard data.count <= maximumSourceBytes else {
            throw DrawIOBoardCodecError.sourceTooLarge
        }
        let folded = source.lowercased()
        let forbidden = [
            "<!doctype", "<!entity", "<script", "<foreignobject",
            "xlink:href=", " href=", " src=",
        ]
        guard !forbidden.contains(where: folded.contains) else {
            throw DrawIOBoardCodecError.unsafeXML
        }

        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawMXFile, delegate.sawGraphModel else {
            throw DrawIOBoardCodecError.malformedXML
        }
        guard delegate.schemaVersion == 1 else {
            throw DrawIOBoardCodecError.unsupportedSchema
        }
        guard let canvasSize = delegate.canvasSize else {
            throw DrawIOBoardCodecError.missingCanvas
        }

        let elements = try delegate.cells.map(makeElement)
        do {
            return try BoardDocument(
                schemaVersion: delegate.schemaVersion,
                canvas: BoardCanvas(size: canvasSize),
                elements: elements
            )
        } catch {
            throw DrawIOBoardCodecError.invalidElement
        }
    }

    private func encode(
        _ element: BoardElement,
        cellID: String,
        visualCellID: String?,
        elementCellIDs: [BoardElementID: String]
    ) throws -> [String] {
        switch element {
        case .box(let box):
            try validateXMLText(box.label)
            let visual = box.kind.visual
            let visualCellID = visualCellID ?? "__ia_node_visual"
            let visualURI = visual.drawIOVisualOverlayDataURI(
                canvasSize: CGSize(
                    width: box.frame.size.width,
                    height: box.frame.size.height
                ),
                strokeHex: box.stroke.hexRGB
            )
            return [
                "        <mxCell id=\"\(attribute(cellID))\" value=\"\(attribute(box.label))\" style=\"\(attribute(visual.drawIOShapeStyle));whiteSpace=wrap;html=0;verticalAlign=bottom;spacingBottom=8;fillColor=#\(attribute(box.fill.hexRGB));strokeColor=none;\" vertex=\"1\" parent=\"1\" iaKind=\"box\" iaElementID=\"\(attribute(box.id.rawValue))\" iaLabel=\"\(attribute(box.label))\" iaNodeKind=\"\(attribute(box.kind.rawValue))\" iaNodeVisual=\"\(attribute(visual.stableKey))\" iaPictogram=\"\(attribute(visual.pictogram.rawValue))\" iaDrawIOShapeStyle=\"\(attribute(visual.drawIOShapeStyle))\" iaFill=\"\(attribute(box.fill.hexRGB))\" iaStroke=\"\(attribute(box.stroke.hexRGB))\">",
                "          <mxGeometry x=\"\(number(box.frame.origin.x))\" y=\"\(number(box.frame.origin.y))\" width=\"\(number(box.frame.size.width))\" height=\"\(number(box.frame.size.height))\" as=\"geometry\"/>",
                "        </mxCell>",
                "        <mxCell id=\"\(attribute(visualCellID))\" value=\"\" style=\"shape=image;imageAspect=0;aspect=fixed;pointerEvents=0;image=\(attribute(visualURI));\" vertex=\"1\" parent=\"\(attribute(cellID))\" connectable=\"0\" locked=\"1\" selectable=\"0\">",
                "          <mxGeometry x=\"0\" y=\"0\" width=\"\(number(box.frame.size.width))\" height=\"\(number(box.frame.size.height))\" as=\"geometry\"/>",
                "        </mxCell>",
            ]

        case .connector(let connector):
            try validateXMLText(connector.label)
            let route = BoardOrthogonalConnectorRoute(
                start: connector.start.point,
                end: connector.end.point
            )
            let source = connector.start.elementID.map {
                " source=\"\(attribute(elementCellIDs[$0] ?? $0.rawValue))\" iaSourceElementID=\"\(attribute($0.rawValue))\""
            } ?? ""
            let target = connector.end.elementID.map {
                " target=\"\(attribute(elementCellIDs[$0] ?? $0.rawValue))\" iaTargetElementID=\"\(attribute($0.rawValue))\""
            } ?? ""
            var rows = [
                "        <mxCell id=\"\(attribute(cellID))\" value=\"\(attribute(connector.label))\" style=\"edgeStyle=orthogonalEdgeStyle;rounded=1;html=0;endArrow=block;strokeColor=#\(attribute(connector.stroke.hexRGB));\" edge=\"1\" parent=\"1\"\(source)\(target) iaKind=\"connector\" iaElementID=\"\(attribute(connector.id.rawValue))\" iaStroke=\"\(attribute(connector.stroke.hexRGB))\">",
                "          <mxGeometry relative=\"1\" as=\"geometry\">",
                "            <mxPoint x=\"\(number(connector.start.point.x))\" y=\"\(number(connector.start.point.y))\" as=\"sourcePoint\"/>",
                "            <mxPoint x=\"\(number(connector.end.point.x))\" y=\"\(number(connector.end.point.y))\" as=\"targetPoint\"/>",
            ]
            let waypoints = route.points.dropFirst().dropLast()
            if !waypoints.isEmpty {
                rows.append("            <Array as=\"points\">")
                for point in waypoints {
                    rows.append(
                        "              <mxPoint x=\"\(number(point.x))\" y=\"\(number(point.y))\"/>"
                    )
                }
                rows.append("            </Array>")
            }
            rows.append(contentsOf: [
                "          </mxGeometry>",
                "        </mxCell>",
            ])
            return rows

        case .label(let label):
            try validateXMLText(label.text)
            return [
                "        <mxCell id=\"\(attribute(cellID))\" value=\"\(attribute(label.text))\" style=\"text;html=0;align=left;verticalAlign=middle;whiteSpace=wrap;fontColor=#\(attribute(label.color.hexRGB));\" vertex=\"1\" parent=\"1\" iaKind=\"label\" iaElementID=\"\(attribute(label.id.rawValue))\" iaTextColor=\"\(attribute(label.color.hexRGB))\">",
                "          <mxGeometry x=\"\(number(label.origin.x))\" y=\"\(number(label.origin.y))\" width=\"240\" height=\"32\" as=\"geometry\"/>",
                "        </mxCell>",
            ]

        case .stroke(let stroke):
            var rows = [
                "        <mxCell id=\"\(attribute(cellID))\" value=\"\" style=\"edgeStyle=none;rounded=1;html=0;endArrow=none;strokeColor=#\(attribute(stroke.color.hexRGB));strokeWidth=\(number(stroke.width));\" edge=\"1\" parent=\"1\" iaKind=\"stroke\" iaElementID=\"\(attribute(stroke.id.rawValue))\" iaWidth=\"\(number(stroke.width))\" iaStroke=\"\(attribute(stroke.color.hexRGB))\">",
                "          <mxGeometry relative=\"1\" as=\"geometry\">",
                "            <mxPoint x=\"\(number(stroke.points[0].x))\" y=\"\(number(stroke.points[0].y))\" as=\"sourcePoint\"/>",
                "            <mxPoint x=\"\(number(stroke.points[stroke.points.count - 1].x))\" y=\"\(number(stroke.points[stroke.points.count - 1].y))\" as=\"targetPoint\"/>",
                "            <Array as=\"points\">",
            ]
            for point in stroke.points.dropFirst().dropLast() {
                rows.append(
                    "              <mxPoint x=\"\(number(point.x))\" y=\"\(number(point.y))\"/>"
                )
            }
            rows.append(contentsOf: [
                "            </Array>",
                "          </mxGeometry>",
                "        </mxCell>",
            ])
            return rows
        }
    }

    private func makeElement(_ cell: ParsedCell) throws -> BoardElement {
        guard let idValue = cell.attributes["iaElementID"]
            ?? cell.attributes["id"] else {
            throw DrawIOBoardCodecError.invalidElement
        }
        let id = BoardElementID(idValue)
        let value = cell.attributes["value"] ?? ""
        switch cell.kind {
        case "box":
            let frame = try geometryRect(cell)
            guard let kind = BoardNodeKind(
                rawValue: cell.attributes["iaNodeKind"] ?? BoardNodeKind.generic.rawValue
            ) else {
                throw DrawIOBoardCodecError.invalidElement
            }
            return .box(
                BoardBox(
                    id: id,
                    frame: frame,
                    label: cell.attributes["iaLabel"] ?? value,
                    kind: kind,
                    fill: try color(cell, key: "iaFill"),
                    stroke: try color(cell, key: "iaStroke")
                )
            )
        case "connector":
            guard let start = cell.sourcePoint, let end = cell.targetPoint else {
                throw DrawIOBoardCodecError.invalidElement
            }
            return .connector(
                BoardConnector(
                    id: id,
                    start: BoardConnectorEndpoint(
                        point: start,
                        elementID: (
                            cell.attributes["iaSourceElementID"]
                                ?? cell.attributes["source"]
                        ).map {
                            BoardElementID($0)
                        }
                    ),
                    end: BoardConnectorEndpoint(
                        point: end,
                        elementID: (
                            cell.attributes["iaTargetElementID"]
                                ?? cell.attributes["target"]
                        ).map {
                            BoardElementID($0)
                        }
                    ),
                    label: value,
                    stroke: try color(cell, key: "iaStroke")
                )
            )
        case "label":
            guard let x = double(cell.geometry["x"]),
                  let y = double(cell.geometry["y"]) else {
                throw DrawIOBoardCodecError.invalidElement
            }
            return .label(
                BoardLabel(
                    id: id,
                    origin: BoardPoint(x: x, y: y),
                    text: value,
                    color: try color(cell, key: "iaTextColor")
                )
            )
        case "stroke":
            guard let start = cell.sourcePoint, let end = cell.targetPoint,
                  let width = double(cell.attributes["iaWidth"]) else {
                throw DrawIOBoardCodecError.invalidElement
            }
            return .stroke(
                BoardStroke(
                    id: id,
                    points: [start] + cell.waypoints + [end],
                    width: width,
                    color: try color(cell, key: "iaStroke")
                )
            )
        default:
            throw DrawIOBoardCodecError.invalidElement
        }
    }

    private func geometryRect(_ cell: ParsedCell) throws -> BoardRect {
        guard let x = double(cell.geometry["x"]),
              let y = double(cell.geometry["y"]),
              let width = double(cell.geometry["width"]),
              let height = double(cell.geometry["height"]) else {
            throw DrawIOBoardCodecError.invalidElement
        }
        return BoardRect(
            origin: BoardPoint(x: x, y: y),
            size: BoardSize(width: width, height: height)
        )
    }

    private func makeElementCellIDs(
        _ elements: [BoardElement]
    ) -> [BoardElementID: String] {
        let canonicalIDs = Set(elements.map { $0.id.rawValue })
        var result: [BoardElementID: String] = [:]
        var reserved = canonicalIDs.union(["0", "1"])

        for element in elements where element.id.rawValue != "0"
            && element.id.rawValue != "1" {
            result[element.id] = element.id.rawValue
        }
        for element in elements where element.id.rawValue == "0"
            || element.id.rawValue == "1" {
            var candidate = "__ia_element_\(element.id.rawValue)"
            while reserved.contains(candidate) {
                candidate.append("_")
            }
            reserved.insert(candidate)
            result[element.id] = candidate
        }
        return result
    }

    private func color(_ cell: ParsedCell, key: String) throws -> BoardColor {
        guard let value = cell.attributes[key] else {
            throw DrawIOBoardCodecError.invalidElement
        }
        return BoardColor(hexRGB: value)
    }

    private func double(_ value: String?) -> Double? {
        guard let value, let result = Double(value), result.isFinite else {
            return nil
        }
        return result
    }

    private func attribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\t", with: "&#9;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#13;")
    }

    private func validateXMLText(_ value: String) throws {
        let isSafe = value.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value == 0x9 || value == 0xA || value == 0xD
                || (0x20...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value)
                || (0x10000...0x10FFFF).contains(value)
        }
        guard isSafe else { throw DrawIOBoardCodecError.invalidElement }
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

private struct ParsedCell {
    let kind: String
    let attributes: [String: String]
    var geometry: [String: String] = [:]
    var sourcePoint: BoardPoint?
    var targetPoint: BoardPoint?
    var waypoints: [BoardPoint] = []
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    private(set) var sawMXFile = false
    private(set) var sawGraphModel = false
    private(set) var schemaVersion = 0
    private(set) var canvasSize: BoardSize?
    private(set) var cells: [ParsedCell] = []

    private var currentCellIndex: Int?
    private var isInsideWaypointArray = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "mxfile":
            sawMXFile = true
        case "mxGraphModel":
            sawGraphModel = true
            schemaVersion = Int(attributeDict["iaSchemaVersion"] ?? "") ?? 0
            if let width = Double(attributeDict["pageWidth"] ?? ""),
               let height = Double(attributeDict["pageHeight"] ?? ""),
               width.isFinite, height.isFinite {
                canvasSize = BoardSize(width: width, height: height)
            }
        case "mxCell":
            guard let kind = attributeDict["iaKind"] else { return }
            cells.append(ParsedCell(kind: kind, attributes: attributeDict))
            currentCellIndex = cells.count - 1
        case "mxGeometry":
            guard let currentCellIndex else { return }
            cells[currentCellIndex].geometry = attributeDict
        case "Array":
            isInsideWaypointArray = attributeDict["as"] == "points"
        case "mxPoint":
            guard let currentCellIndex,
                  let x = Double(attributeDict["x"] ?? ""),
                  let y = Double(attributeDict["y"] ?? ""),
                  x.isFinite, y.isFinite else {
                return
            }
            let point = BoardPoint(x: x, y: y)
            switch attributeDict["as"] {
            case "sourcePoint": cells[currentCellIndex].sourcePoint = point
            case "targetPoint": cells[currentCellIndex].targetPoint = point
            default:
                if isInsideWaypointArray {
                    cells[currentCellIndex].waypoints.append(point)
                }
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "mxCell" { currentCellIndex = nil }
        if elementName == "Array" { isInsideWaypointArray = false }
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }
}
