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

    /// A short, deterministic glyph shared by the live canvas and every
    /// derivative. It deliberately avoids font-specific symbol libraries.
    var glyphToken: String {
        switch self {
        case .generic: "GEN"
        case .client: "WEB"
        case .service: "SVC"
        case .database: "DB"
        case .queue: "Q"
        case .storage: "OBJ"
        }
    }

    var drawIOShape: String {
        switch self {
        case .database: "cylinder3"
        case .storage: "folder"
        default: "rectangle"
        }
    }
}
