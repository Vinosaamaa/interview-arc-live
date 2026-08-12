import Foundation

public struct BoardElementID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct BoardRevisionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct BoardExportID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct BoardPoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct BoardSize: Codable, Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct BoardRect: Codable, Sendable, Equatable {
    public let origin: BoardPoint
    public let size: BoardSize

    public init(origin: BoardPoint, size: BoardSize) {
        self.origin = origin
        self.size = size
    }
}

public struct BoardCanvas: Codable, Sendable, Equatable {
    public let size: BoardSize

    public init(size: BoardSize) {
        self.size = size
    }
}

/// Six-digit RGB color. Validation occurs at the bounded Board Document or
/// export-settings boundary so invalid transient editor values are never
/// accepted into the Session Manifest.
public struct BoardColor: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(hexRGB: String) { self.rawValue = hexRGB }
    public var hexRGB: String { rawValue }
    public var description: String { rawValue }

    public static let ink = BoardColor(hexRGB: "1f2937")
    public static let surface = BoardColor(hexRGB: "f8fafc")
    public static let accent = BoardColor(hexRGB: "2563eb")
    public static let nodeOutline = BoardColor(hexRGB: "4b3abf")
    public static let white = BoardColor(hexRGB: "ffffff")
}

public enum BoardNodeKind: String, Codable, Sendable, Equatable {
    case generic
    case decision
    case ellipse
    case client
    case service
    case database
    case queue
    case storage
}

public struct BoardBox: Codable, Sendable, Equatable {
    public let id: BoardElementID
    public let frame: BoardRect
    public let label: String
    public let kind: BoardNodeKind
    public let fill: BoardColor
    public let stroke: BoardColor

    public init(
        id: BoardElementID,
        frame: BoardRect,
        label: String,
        kind: BoardNodeKind = .generic,
        fill: BoardColor = .white,
        stroke: BoardColor = .nodeOutline
    ) {
        self.id = id
        self.frame = frame
        self.label = label
        self.kind = kind
        self.fill = fill
        self.stroke = stroke
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case frame
        case label
        case kind
        case fill
        case stroke
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(BoardElementID.self, forKey: .id),
            frame: try container.decode(BoardRect.self, forKey: .frame),
            label: try container.decode(String.self, forKey: .label),
            kind: try container.decodeIfPresent(BoardNodeKind.self, forKey: .kind)
                ?? .generic,
            fill: try container.decode(BoardColor.self, forKey: .fill),
            stroke: try container.decode(BoardColor.self, forKey: .stroke)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(frame, forKey: .frame)
        try container.encode(label, forKey: .label)
        try container.encode(kind, forKey: .kind)
        try container.encode(fill, forKey: .fill)
        try container.encode(stroke, forKey: .stroke)
    }
}

public enum BoardConnectorAnchorPolicy: String, Codable, Sendable, Equatable {
    case automatic
    case preserved
}

public struct BoardConnectorEndpoint: Codable, Sendable, Equatable {
    public let point: BoardPoint
    public let elementID: BoardElementID?
    public let anchorPolicy: BoardConnectorAnchorPolicy

    public init(
        point: BoardPoint,
        elementID: BoardElementID? = nil,
        anchorPolicy: BoardConnectorAnchorPolicy = .preserved
    ) {
        self.point = point
        self.elementID = elementID
        self.anchorPolicy = anchorPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case point
        case elementID
        case anchorPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            point: try container.decode(BoardPoint.self, forKey: .point),
            elementID: try container.decodeIfPresent(
                BoardElementID.self,
                forKey: .elementID
            ),
            anchorPolicy: try container.decodeIfPresent(
                BoardConnectorAnchorPolicy.self,
                forKey: .anchorPolicy
            ) ?? .preserved
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(point, forKey: .point)
        try container.encodeIfPresent(elementID, forKey: .elementID)
        try container.encode(anchorPolicy, forKey: .anchorPolicy)
    }
}

public struct BoardConnector: Codable, Sendable, Equatable {
    public let id: BoardElementID
    public let start: BoardConnectorEndpoint
    public let end: BoardConnectorEndpoint
    public let label: String
    public let stroke: BoardColor

    public init(
        id: BoardElementID,
        start: BoardConnectorEndpoint,
        end: BoardConnectorEndpoint,
        label: String = "",
        stroke: BoardColor = .ink
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.label = label
        self.stroke = stroke
    }
}

public struct BoardLabel: Codable, Sendable, Equatable {
    public let id: BoardElementID
    public let origin: BoardPoint
    public let text: String
    public let color: BoardColor

    public init(
        id: BoardElementID,
        origin: BoardPoint,
        text: String,
        color: BoardColor = .ink
    ) {
        self.id = id
        self.origin = origin
        self.text = text
        self.color = color
    }
}

public struct BoardStroke: Codable, Sendable, Equatable {
    public let id: BoardElementID
    public let points: [BoardPoint]
    public let width: Double
    public let color: BoardColor

    public init(
        id: BoardElementID,
        points: [BoardPoint],
        width: Double,
        color: BoardColor = .ink
    ) {
        self.id = id
        self.points = points
        self.width = width
        self.color = color
    }
}

public enum BoardElement: Codable, Sendable, Equatable {
    case box(BoardBox)
    case connector(BoardConnector)
    case label(BoardLabel)
    case stroke(BoardStroke)

    public var id: BoardElementID {
        switch self {
        case .box(let box): box.id
        case .connector(let connector): connector.id
        case .label(let label): label.id
        case .stroke(let stroke): stroke.id
        }
    }
}

public enum BoardDocumentValidationError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidCanvas
    case tooManyElements(maximum: Int)
    case invalidElementID(BoardElementID)
    case duplicateElementID(BoardElementID)
    case invalidGeometry(elementID: BoardElementID)
    case emptyStroke(elementID: BoardElementID)
    case tooManyStrokePoints(elementID: BoardElementID, maximum: Int)
    case tooManyTotalStrokePoints(maximum: Int)
    case textTooLong(elementID: BoardElementID, maximumUTF8Bytes: Int)
    case invalidColor(elementID: BoardElementID)
    case invalidConnectorReference(elementID: BoardElementID, referencedID: BoardElementID)
}

/// Canonical, versioned editable Board source retained in the Session
/// Manifest. Rendering formats are derived from this bounded value.
public struct BoardDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumCanvasDimension = 32_768.0
    public static let maximumElements = 4_096
    public static let maximumElementIDUTF8Bytes = 160
    public static let maximumTextUTF8Bytes = 16 * 1_024
    public static let maximumStrokePoints = 16_384
    public static let maximumTotalStrokePoints = 131_072
    public static let maximumStrokeWidth = 256.0

    public let schemaVersion: Int
    public let canvas: BoardCanvas
    public let elements: [BoardElement]

    public init(
        schemaVersion: Int = BoardDocument.currentSchemaVersion,
        canvas: BoardCanvas,
        elements: [BoardElement]
    ) throws {
        try Self.validate(schemaVersion: schemaVersion, canvas: canvas, elements: elements)
        self.schemaVersion = schemaVersion
        self.canvas = canvas
        self.elements = elements
    }

    public static var empty: BoardDocument {
        // These fixed literals satisfy the same validation used for decoded
        // and editor-supplied source.
        try! BoardDocument(
            canvas: BoardCanvas(size: BoardSize(width: 1_200, height: 800)),
            elements: []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case canvas
        case elements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            canvas: container.decode(BoardCanvas.self, forKey: .canvas),
            elements: container.decode([BoardElement].self, forKey: .elements)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(elements, forKey: .elements)
    }

    private static func validate(
        schemaVersion: Int,
        canvas: BoardCanvas,
        elements: [BoardElement]
    ) throws {
        guard schemaVersion == currentSchemaVersion else {
            throw BoardDocumentValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard valid(size: canvas.size) else {
            throw BoardDocumentValidationError.invalidCanvas
        }
        guard elements.count <= maximumElements else {
            throw BoardDocumentValidationError.tooManyElements(maximum: maximumElements)
        }

        var ids = Set<BoardElementID>()
        var boxIDs = Set<BoardElementID>()
        var totalStrokePoints = 0
        for element in elements {
            let id = element.id
            guard valid(elementID: id) else {
                throw BoardDocumentValidationError.invalidElementID(id)
            }
            guard ids.insert(id).inserted else {
                throw BoardDocumentValidationError.duplicateElementID(id)
            }

            switch element {
            case .box(let box):
                boxIDs.insert(box.id)
                guard valid(point: box.frame.origin), valid(size: box.frame.size) else {
                    throw BoardDocumentValidationError.invalidGeometry(elementID: box.id)
                }
                try validate(text: box.label, elementID: box.id)
                guard valid(color: box.fill), valid(color: box.stroke) else {
                    throw BoardDocumentValidationError.invalidColor(elementID: box.id)
                }

            case .connector(let connector):
                guard valid(point: connector.start.point), valid(point: connector.end.point) else {
                    throw BoardDocumentValidationError.invalidGeometry(elementID: connector.id)
                }
                try validate(text: connector.label, elementID: connector.id)
                guard valid(color: connector.stroke) else {
                    throw BoardDocumentValidationError.invalidColor(elementID: connector.id)
                }

            case .label(let label):
                guard valid(point: label.origin) else {
                    throw BoardDocumentValidationError.invalidGeometry(elementID: label.id)
                }
                try validate(text: label.text, elementID: label.id)
                guard valid(color: label.color) else {
                    throw BoardDocumentValidationError.invalidColor(elementID: label.id)
                }

            case .stroke(let stroke):
                guard !stroke.points.isEmpty else {
                    throw BoardDocumentValidationError.emptyStroke(elementID: stroke.id)
                }
                guard stroke.points.count <= maximumStrokePoints else {
                    throw BoardDocumentValidationError.tooManyStrokePoints(
                        elementID: stroke.id,
                        maximum: maximumStrokePoints
                    )
                }
                totalStrokePoints += stroke.points.count
                guard totalStrokePoints <= maximumTotalStrokePoints else {
                    throw BoardDocumentValidationError.tooManyTotalStrokePoints(
                        maximum: maximumTotalStrokePoints
                    )
                }
                guard stroke.points.allSatisfy(valid(point:)),
                      stroke.width.isFinite,
                      stroke.width > 0,
                      stroke.width <= maximumStrokeWidth else {
                    throw BoardDocumentValidationError.invalidGeometry(elementID: stroke.id)
                }
                guard valid(color: stroke.color) else {
                    throw BoardDocumentValidationError.invalidColor(elementID: stroke.id)
                }
            }
        }

        for element in elements {
            guard case .connector(let connector) = element else { continue }
            for reference in [connector.start.elementID, connector.end.elementID].compactMap({ $0 }) {
                guard boxIDs.contains(reference) else {
                    throw BoardDocumentValidationError.invalidConnectorReference(
                        elementID: connector.id,
                        referencedID: reference
                    )
                }
            }
        }
    }

    private static func validate(text: String, elementID: BoardElementID) throws {
        guard text.utf8.count <= maximumTextUTF8Bytes else {
            throw BoardDocumentValidationError.textTooLong(
                elementID: elementID,
                maximumUTF8Bytes: maximumTextUTF8Bytes
            )
        }
    }

    private static func valid(elementID: BoardElementID) -> Bool {
        let value = elementID.rawValue
        guard !value.isEmpty,
              value.utf8.count <= maximumElementIDUTF8Bytes else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
        }
    }

    private static func valid(point: BoardPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
            && abs(point.x) <= maximumCanvasDimension * 2
            && abs(point.y) <= maximumCanvasDimension * 2
    }

    private static func valid(size: BoardSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
            && size.width <= maximumCanvasDimension
            && size.height <= maximumCanvasDimension
    }

    private static func valid(color: BoardColor) -> Bool {
        color.rawValue.count == 6 && color.rawValue.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0)))
                || ("a"..."f").contains(Character(String($0)))
                || ("A"..."F").contains(Character(String($0)))
        }
    }
}

public struct BoardRevision: Codable, Sendable, Equatable {
    public let id: BoardRevisionID
    public let ordinal: Int
    public let saveCommandID: CommandID
    public let document: BoardDocument

    public init(
        id: BoardRevisionID,
        ordinal: Int,
        saveCommandID: CommandID,
        document: BoardDocument
    ) {
        self.id = id
        self.ordinal = ordinal
        self.saveCommandID = saveCommandID
        self.document = document
    }
}

public enum CandidateTurnBoardAttachment: Codable, Sendable, Equatable {
    case noBoard
    case revision(BoardRevisionID)
}

public enum BoardArtifactIdentityValidationError: Error, Sendable, Equatable {
    case invalidRelativeIdentity
}

/// Validated session-relative artifact identity. It is never a URL or an
/// absolute machine path.
public struct BoardArtifactIdentity: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public static let maximumUTF8Bytes = 512
    public let rawValue: String

    public init(validating rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Bytes,
              !rawValue.hasPrefix("/"),
              !rawValue.contains("\\"),
              !rawValue.contains(":"),
              !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              rawValue.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw BoardArtifactIdentityValidationError.invalidRelativeIdentity
        }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        try? self.init(validating: rawValue)
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum BoardExportSettingsValidationError: Error, Sendable, Equatable {
    case invalidViewport
    case invalidScale
    case invalidBackground
}

public struct BoardExportSettings: Codable, Sendable, Equatable {
    public static let maximumScale = 4.0
    public static let maximumPixelDimension = 8_192.0
    public static let maximumPixelCount = 32_000_000.0
    public let viewport: BoardSize
    public let scale: Double
    public let background: BoardColor

    public init(
        viewport: BoardSize,
        scale: Double,
        background: BoardColor = .white
    ) throws {
        guard viewport.width.isFinite,
              viewport.height.isFinite,
              viewport.width > 0,
              viewport.height > 0,
              viewport.width <= BoardDocument.maximumCanvasDimension,
              viewport.height <= BoardDocument.maximumCanvasDimension else {
            throw BoardExportSettingsValidationError.invalidViewport
        }
        guard scale.isFinite, scale > 0, scale <= Self.maximumScale else {
            throw BoardExportSettingsValidationError.invalidScale
        }
        let pixelWidth = viewport.width * scale
        let pixelHeight = viewport.height * scale
        guard pixelWidth <= Self.maximumPixelDimension,
              pixelHeight <= Self.maximumPixelDimension,
              pixelWidth * pixelHeight <= Self.maximumPixelCount else {
            throw BoardExportSettingsValidationError.invalidViewport
        }
        guard background.rawValue.count == 6,
              background.rawValue.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
              }) else {
            throw BoardExportSettingsValidationError.invalidBackground
        }
        self.viewport = viewport
        self.scale = scale
        self.background = background
    }

    private enum CodingKeys: String, CodingKey {
        case viewport
        case scale
        case background
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            viewport: container.decode(BoardSize.self, forKey: .viewport),
            scale: container.decode(Double.self, forKey: .scale),
            background: container.decode(BoardColor.self, forKey: .background)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(scale, forKey: .scale)
        try container.encode(background, forKey: .background)
    }
}

public struct BoardArtifactIdentities: Codable, Sendable, Equatable {
    public let source: BoardArtifactIdentity
    public let svg: BoardArtifactIdentity
    public let png: BoardArtifactIdentity

    public init(
        source: BoardArtifactIdentity,
        svg: BoardArtifactIdentity,
        png: BoardArtifactIdentity
    ) {
        self.source = source
        self.svg = svg
        self.png = png
    }
}

public struct BoardArtifactMetadata: Codable, Sendable, Equatable {
    public let identity: BoardArtifactIdentity
    public let byteCount: Int
    public let sha256: String

    public init(identity: BoardArtifactIdentity, byteCount: Int, sha256: String) {
        self.identity = identity
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct BoardArtifactBundle: Codable, Sendable, Equatable {
    public let source: BoardArtifactMetadata
    public let svg: BoardArtifactMetadata
    public let png: BoardArtifactMetadata

    public init(
        source: BoardArtifactMetadata,
        svg: BoardArtifactMetadata,
        png: BoardArtifactMetadata
    ) {
        self.source = source
        self.svg = svg
        self.png = png
    }
}

public enum BoardExportLifecycle: String, Codable, Sendable, Equatable {
    case authorized
    case ready
    case failed
}

public enum BoardExportFailureReason: String, Codable, Sendable, Equatable {
    case interrupted
    case renderingFailed = "rendering_failed"
    case storageFailed = "storage_failed"
    case validationFailed = "validation_failed"
}

public struct BoardExportFailure: Codable, Sendable, Equatable {
    public let reason: BoardExportFailureReason

    public init(reason: BoardExportFailureReason) {
        self.reason = reason
    }
}

public enum BoardExportOutcome: Codable, Sendable, Equatable {
    case ready(BoardArtifactBundle)
    case failed(BoardExportFailure)
}

public struct BoardExportOperation: Codable, Sendable, Equatable {
    public let id: BoardExportID
    public let authorizationCommandID: CommandID
    public let revisionID: BoardRevisionID
    public let settings: BoardExportSettings
    public let artifactIdentities: BoardArtifactIdentities
    public let lifecycle: BoardExportLifecycle
    public let bundle: BoardArtifactBundle?
    public let failure: BoardExportFailure?

    public init(
        id: BoardExportID,
        authorizationCommandID: CommandID,
        revisionID: BoardRevisionID,
        settings: BoardExportSettings,
        artifactIdentities: BoardArtifactIdentities,
        lifecycle: BoardExportLifecycle = .authorized,
        bundle: BoardArtifactBundle? = nil,
        failure: BoardExportFailure? = nil
    ) {
        self.id = id
        self.authorizationCommandID = authorizationCommandID
        self.revisionID = revisionID
        self.settings = settings
        self.artifactIdentities = artifactIdentities
        self.lifecycle = lifecycle
        self.bundle = bundle
        self.failure = failure
    }
}

public struct BoardWorkspace: Codable, Sendable, Equatable {
    public let draft: BoardDocument
    public let revisions: [BoardRevision]
    public let selectedRevisionID: BoardRevisionID?
    public let exports: [BoardExportOperation]

    public init(
        draft: BoardDocument,
        revisions: [BoardRevision] = [],
        selectedRevisionID: BoardRevisionID? = nil,
        exports: [BoardExportOperation] = []
    ) {
        self.draft = draft
        self.revisions = revisions
        self.selectedRevisionID = selectedRevisionID
        self.exports = exports
    }

    public static var empty: BoardWorkspace {
        BoardWorkspace(draft: .empty)
    }
}
