import Foundation

public struct SessionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct CommandID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct TurnID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum InterviewRoomPhase: String, Codable, Sendable, Equatable {
    case ready
    case candidateFloor
    case interviewerProcessing
    case interviewerTurn
    case completed
}

public enum TurnMode: String, Codable, Sendable, Equatable {
    case cueOnly
    case patientAuto
    case manual
}

public enum TranscriptQuality: String, Codable, Sendable, Equatable {
    case verified
    case bestAvailable = "best_available"
    case possibleContamination = "possible_contamination"
}

/// The best nonempty transcript candidate and the quality label attached to it.
/// The body is retained verbatim; the session Module never rewrites speech.
public struct CandidateTranscript: Codable, Sendable, Equatable {
    public let body: String
    public let quality: TranscriptQuality

    public init(body: String, quality: TranscriptQuality) {
        self.body = body
        self.quality = quality
    }
}

public struct CandidateTurn: Codable, Sendable, Equatable {
    public let id: TurnID
    public let commandID: CommandID
    public let transcript: CandidateTranscript
    public let segmentIDs: [SegmentID]

    public init(
        id: TurnID,
        commandID: CommandID,
        transcript: CandidateTranscript,
        segmentIDs: [SegmentID] = []
    ) {
        self.id = id
        self.commandID = commandID
        self.transcript = transcript
        self.segmentIDs = segmentIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case commandID
        case transcript
        case segmentIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TurnID.self, forKey: .id)
        commandID = try container.decode(CommandID.self, forKey: .commandID)
        transcript = try container.decode(CandidateTranscript.self, forKey: .transcript)
        segmentIDs = try container.decodeIfPresent([SegmentID].self, forKey: .segmentIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(segmentIDs, forKey: .segmentIDs)
    }
}

/// The canonical response value returned by an Interviewer Runtime Adapter.
/// Both representations must be generated together and remain one identity.
public struct CanonicalInterviewerResponse: Codable, Sendable, Equatable {
    public let displayMarkdown: String
    public let spokenText: String

    public init(displayMarkdown: String, spokenText: String) {
        self.displayMarkdown = displayMarkdown
        self.spokenText = spokenText
    }
}

public struct InterviewerTurn: Codable, Sendable, Equatable {
    public let id: TurnID
    public let commandID: CommandID
    public let replyToTurnID: TurnID
    public let response: CanonicalInterviewerResponse

    public init(
        id: TurnID,
        commandID: CommandID,
        replyToTurnID: TurnID,
        response: CanonicalInterviewerResponse
    ) {
        self.id = id
        self.commandID = commandID
        self.replyToTurnID = replyToTurnID
        self.response = response
    }

    public var displayMarkdown: String { response.displayMarkdown }
    public var spokenText: String { response.spokenText }
}

public enum InterviewTurn: Codable, Sendable, Equatable {
    case candidate(CandidateTurn)
    case interviewer(InterviewerTurn)

    public var id: TurnID {
        switch self {
        case .candidate(let turn): turn.id
        case .interviewer(let turn): turn.id
        }
    }
}

struct AppliedCommandRecord: Codable, Sendable, Equatable {
    let commandID: CommandID
    let payloadFingerprint: String
    let resultingRevision: Int
}

/// Canonical, monotonically revisioned recovery state for one Interview Room.
public struct SessionManifest: Codable, Sendable, Equatable {
    public let sessionID: SessionID
    public let activityID: String
    public let phase: InterviewRoomPhase
    public let turnMode: TurnMode
    public let turns: [InterviewTurn]
    public let segments: [CandidateSegment]
    public let revision: Int

    let appliedCommands: [AppliedCommandRecord]

    init(
        sessionID: SessionID,
        activityID: String,
        phase: InterviewRoomPhase,
        turnMode: TurnMode,
        turns: [InterviewTurn],
        segments: [CandidateSegment] = [],
        revision: Int,
        appliedCommands: [AppliedCommandRecord]
    ) {
        self.sessionID = sessionID
        self.activityID = activityID
        self.phase = phase
        self.turnMode = turnMode
        self.turns = turns
        self.segments = segments
        self.revision = revision
        self.appliedCommands = appliedCommands
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case activityID
        case phase
        case turnMode
        case turns
        case segments
        case revision
        case appliedCommands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        activityID = try container.decode(String.self, forKey: .activityID)
        phase = try container.decode(InterviewRoomPhase.self, forKey: .phase)
        turnMode = try container.decode(TurnMode.self, forKey: .turnMode)
        turns = try container.decode([InterviewTurn].self, forKey: .turns)
        segments = try container.decodeIfPresent([CandidateSegment].self, forKey: .segments) ?? []
        revision = try container.decode(Int.self, forKey: .revision)
        appliedCommands = try container.decode(
            [AppliedCommandRecord].self,
            forKey: .appliedCommands
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(activityID, forKey: .activityID)
        try container.encode(phase, forKey: .phase)
        try container.encode(turnMode, forKey: .turnMode)
        try container.encode(turns, forKey: .turns)
        try container.encode(segments, forKey: .segments)
        try container.encode(revision, forKey: .revision)
        try container.encode(appliedCommands, forKey: .appliedCommands)
    }
}

/// Immutable projection returned by the InterviewRoomSession Interface.
public struct InterviewRoomSnapshot: Sendable, Equatable {
    public let sessionID: SessionID
    public let activityID: String
    public let phase: InterviewRoomPhase
    public let turnMode: TurnMode
    public let turns: [InterviewTurn]
    public let segments: [CandidateSegment]
    public let revision: Int

    init(manifest: SessionManifest) {
        sessionID = manifest.sessionID
        activityID = manifest.activityID
        phase = manifest.phase
        turnMode = manifest.turnMode
        turns = manifest.turns
        segments = manifest.segments
        revision = manifest.revision
    }
}
