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

/// The specialty contract selected by the owning Interview Arc Activity.
/// Additional specialties belong here only after their prompt contract exists.
public enum ActivitySpecialty: String, Codable, Sendable, Equatable {
    case systemDesign = "system_design"
    case coding = "coding"
    /// issue-70-behavioral-specialty: local Behavioral room prompt. Hosted `/live/v1` writes wait on interview-arc#389.
    case behavioral = "behavioral"
}

public enum ActivityPromptValidationError: Error, Sendable, Equatable {
    case emptyStage
    case stageTooLong(maximumUTF8Bytes: Int)
    case emptyQuestion
    case questionTooLong(maximumUTF8Bytes: Int)
    case tooManyRequestedParts(maximum: Int)
    case emptyRequestedPart(index: Int)
    case requestedPartTooLong(index: Int, maximumUTF8Bytes: Int)
}

/// Durable interviewer context bound to a Session Manifest.
///
/// Validation preserves every accepted string verbatim while bounding the
/// provider-neutral prompt shape independently of presentation copy.
public struct ActivityPrompt: Codable, Sendable, Equatable {
    public static let maximumStageUTF8Bytes = 256
    public static let maximumQuestionUTF8Bytes = 16 * 1_024
    public static let maximumRequestedParts = 24
    public static let maximumRequestedPartUTF8Bytes = 4 * 1_024

    public let specialty: ActivitySpecialty
    public let stage: String
    public let question: String
    public let requestedParts: [String]

    public init(
        specialty: ActivitySpecialty,
        stage: String,
        question: String,
        requestedParts: [String]
    ) throws {
        try Self.validate(
            stage: stage,
            question: question,
            requestedParts: requestedParts
        )
        self.specialty = specialty
        self.stage = stage
        self.question = question
        self.requestedParts = requestedParts
    }

    private enum CodingKeys: String, CodingKey {
        case specialty
        case stage
        case question
        case requestedParts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            specialty: container.decode(ActivitySpecialty.self, forKey: .specialty),
            stage: container.decode(String.self, forKey: .stage),
            question: container.decode(String.self, forKey: .question),
            requestedParts: container.decode([String].self, forKey: .requestedParts)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(specialty, forKey: .specialty)
        try container.encode(stage, forKey: .stage)
        try container.encode(question, forKey: .question)
        try container.encode(requestedParts, forKey: .requestedParts)
    }

    private static func validate(
        stage: String,
        question: String,
        requestedParts: [String]
    ) throws {
        guard !stage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActivityPromptValidationError.emptyStage
        }
        guard stage.utf8.count <= maximumStageUTF8Bytes else {
            throw ActivityPromptValidationError.stageTooLong(
                maximumUTF8Bytes: maximumStageUTF8Bytes
            )
        }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActivityPromptValidationError.emptyQuestion
        }
        guard question.utf8.count <= maximumQuestionUTF8Bytes else {
            throw ActivityPromptValidationError.questionTooLong(
                maximumUTF8Bytes: maximumQuestionUTF8Bytes
            )
        }
        guard requestedParts.count <= maximumRequestedParts else {
            throw ActivityPromptValidationError.tooManyRequestedParts(
                maximum: maximumRequestedParts
            )
        }
        for (index, requestedPart) in requestedParts.enumerated() {
            guard !requestedPart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActivityPromptValidationError.emptyRequestedPart(index: index)
            }
            guard requestedPart.utf8.count <= maximumRequestedPartUTF8Bytes else {
                throw ActivityPromptValidationError.requestedPartTooLong(
                    index: index,
                    maximumUTF8Bytes: maximumRequestedPartUTF8Bytes
                )
            }
        }
    }
}

public enum CandidateNotesValidationError: Error, Sendable, Equatable {
    case bodyTooLong(maximumUTF8Bytes: Int)
}

/// Private candidate scratch text. It is durable room state, not transcript,
/// prompt, spoken output, Board evidence, or hosted mutation data.
public struct CandidateNotes: Codable, Sendable, Equatable {
    public static let maximumBodyUTF8Bytes = 16 * 1_024

    public let body: String

    public init(body: String) throws {
        guard body.utf8.count <= Self.maximumBodyUTF8Bytes else {
            throw CandidateNotesValidationError.bodyTooLong(
                maximumUTF8Bytes: Self.maximumBodyUTF8Bytes
            )
        }
        self.body = body
    }

    public static var empty: CandidateNotes {
        CandidateNotes(validatedBody: "")
    }

    private init(validatedBody: String) {
        body = validatedBody
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(body: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(body)
    }
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
    case continuousConversation = "continuous_conversation"

    public static let defaultForNewSession = TurnMode.continuousConversation

    public var usesAutomaticEndpointCompletion: Bool {
        switch self {
        case .patientAuto, .continuousConversation:
            true
        case .cueOnly, .manual:
            false
        }
    }
}

public enum TranscriptQuality: String, Codable, Sendable, Equatable {
    case verified
    case bestAvailable = "best_available"
    case possibleContamination = "possible_contamination"
}

/// The best nonempty transcript candidate and the quality label attached to it.
/// The body is retained verbatim; the session Module never rewrites speech.
public struct CandidateTranscript: Codable, Sendable, Equatable {
    /// Generous safety ceiling for one exact logical Candidate answer.
    public static let maximumBodyUTF8Bytes = 256 * 1_024

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
    public let boardAttachment: CandidateTurnBoardAttachment

    public init(
        id: TurnID,
        commandID: CommandID,
        transcript: CandidateTranscript,
        segmentIDs: [SegmentID] = [],
        boardAttachment: CandidateTurnBoardAttachment = .noBoard
    ) {
        self.id = id
        self.commandID = commandID
        self.transcript = transcript
        self.segmentIDs = segmentIDs
        self.boardAttachment = boardAttachment
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case commandID
        case transcript
        case segmentIDs
        case boardAttachment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TurnID.self, forKey: .id)
        commandID = try container.decode(CommandID.self, forKey: .commandID)
        transcript = try container.decode(CandidateTranscript.self, forKey: .transcript)
        segmentIDs = try container.decodeIfPresent([SegmentID].self, forKey: .segmentIDs) ?? []
        boardAttachment = try container.decodeIfPresent(
            CandidateTurnBoardAttachment.self,
            forKey: .boardAttachment
        ) ?? .noBoard
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(segmentIDs, forKey: .segmentIDs)
        try container.encode(boardAttachment, forKey: .boardAttachment)
    }
}

/// The canonical response value returned by an Interviewer Runtime Adapter.
/// Both representations must be generated together and remain one identity.
public struct CanonicalInterviewerResponse: Codable, Sendable, Equatable {
    public static let maximumDisplayMarkdownUTF8Bytes = 128 * 1_024
    public static let maximumSpokenTextUTF8Bytes = 64 * 1_024

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
    public let activityPrompt: ActivityPrompt
    public let phase: InterviewRoomPhase
    public let turnMode: TurnMode
    public let turns: [InterviewTurn]
    public let segments: [CandidateSegment]
    public let endpointEvaluations: [EndpointEvaluation]
    public let endpointGraces: [EndpointGrace]
    public let floorHolds: [FloorHold]
    public let interviewerUtterances: [InterviewerUtterance]
    public let board: BoardWorkspace
    public let candidateNotes: CandidateNotes
    public let revision: Int

    let appliedCommands: [AppliedCommandRecord]

    public var activeFloorHold: FloorHold? {
        floorHolds.activeHold
    }

    init(
        sessionID: SessionID,
        activityID: String,
        activityPrompt: ActivityPrompt,
        phase: InterviewRoomPhase,
        turnMode: TurnMode,
        turns: [InterviewTurn],
        segments: [CandidateSegment] = [],
        endpointEvaluations: [EndpointEvaluation] = [],
        endpointGraces: [EndpointGrace] = [],
        floorHolds: [FloorHold] = [],
        interviewerUtterances: [InterviewerUtterance] = [],
        board: BoardWorkspace = .empty,
        candidateNotes: CandidateNotes = .empty,
        revision: Int,
        appliedCommands: [AppliedCommandRecord]
    ) {
        self.sessionID = sessionID
        self.activityID = activityID
        self.activityPrompt = activityPrompt
        self.phase = phase
        self.turnMode = turnMode
        self.turns = turns
        self.segments = segments
        self.endpointEvaluations = endpointEvaluations
        self.endpointGraces = endpointGraces
        self.floorHolds = floorHolds
        self.interviewerUtterances = interviewerUtterances
        self.board = board
        self.candidateNotes = candidateNotes
        self.revision = revision
        self.appliedCommands = appliedCommands
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case activityID
        case activityPrompt
        case phase
        case turnMode
        case turns
        case segments
        case endpointEvaluations
        case endpointGraces
        case floorHolds
        case interviewerUtterances
        case board
        case candidateNotes
        case revision
        case appliedCommands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        activityID = try container.decode(String.self, forKey: .activityID)
        activityPrompt = try container.decode(ActivityPrompt.self, forKey: .activityPrompt)
        phase = try container.decode(InterviewRoomPhase.self, forKey: .phase)
        turnMode = try container.decode(TurnMode.self, forKey: .turnMode)
        turns = try container.decode([InterviewTurn].self, forKey: .turns)
        segments = try container.decodeIfPresent([CandidateSegment].self, forKey: .segments) ?? []
        endpointEvaluations = try container.decodeIfPresent(
            [EndpointEvaluation].self,
            forKey: .endpointEvaluations
        ) ?? []
        endpointGraces = try container.decodeIfPresent(
            [EndpointGrace].self,
            forKey: .endpointGraces
        ) ?? []
        floorHolds = try container.decodeIfPresent(
            [FloorHold].self,
            forKey: .floorHolds
        ) ?? []
        interviewerUtterances = try container.decodeIfPresent(
            [InterviewerUtterance].self,
            forKey: .interviewerUtterances
        ) ?? []
        board = try container.decodeIfPresent(BoardWorkspace.self, forKey: .board) ?? .empty
        candidateNotes = try container.decodeIfPresent(
            CandidateNotes.self,
            forKey: .candidateNotes
        ) ?? .empty
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
        try container.encode(activityPrompt, forKey: .activityPrompt)
        try container.encode(phase, forKey: .phase)
        try container.encode(turnMode, forKey: .turnMode)
        try container.encode(turns, forKey: .turns)
        try container.encode(segments, forKey: .segments)
        try container.encode(endpointEvaluations, forKey: .endpointEvaluations)
        try container.encode(endpointGraces, forKey: .endpointGraces)
        try container.encode(floorHolds, forKey: .floorHolds)
        try container.encode(interviewerUtterances, forKey: .interviewerUtterances)
        try container.encode(board, forKey: .board)
        try container.encode(candidateNotes, forKey: .candidateNotes)
        try container.encode(revision, forKey: .revision)
        try container.encode(appliedCommands, forKey: .appliedCommands)
    }
}

/// Immutable projection returned by the InterviewRoomSession Interface.
public struct InterviewRoomSnapshot: Sendable, Equatable {
    public let sessionID: SessionID
    public let activityID: String
    public let activityPrompt: ActivityPrompt
    public let phase: InterviewRoomPhase
    public let turnMode: TurnMode
    public let turns: [InterviewTurn]
    public let segments: [CandidateSegment]
    public let endpointEvaluations: [EndpointEvaluation]
    public let endpointGraces: [EndpointGrace]
    public let floorHolds: [FloorHold]
    public let interviewerUtterances: [InterviewerUtterance]
    public let board: BoardWorkspace
    public let candidateNotes: CandidateNotes
    public let revision: Int

    public var activeFloorHold: FloorHold? {
        floorHolds.activeHold
    }

    public var isFloorHeld: Bool {
        activeFloorHold != nil
    }

    init(manifest: SessionManifest) {
        sessionID = manifest.sessionID
        activityID = manifest.activityID
        activityPrompt = manifest.activityPrompt
        phase = manifest.phase
        turnMode = manifest.turnMode
        turns = manifest.turns
        segments = manifest.segments
        endpointEvaluations = manifest.endpointEvaluations
        endpointGraces = manifest.endpointGraces
        floorHolds = manifest.floorHolds
        interviewerUtterances = manifest.interviewerUtterances
        board = manifest.board
        candidateNotes = manifest.candidateNotes
        revision = manifest.revision
    }
}
