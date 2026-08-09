import Foundation

/// Input presented to the Interviewer Runtime Seam after an explicit Hand off.
public struct InterviewerRequest: Sendable, Equatable {
    /// Core supplies a contiguous suffix containing at most this many complete
    /// visible Candidate/Interviewer turns. The pending Candidate Turn remains
    /// separate and is never truncated.
    public static let maximumPriorVisibleTurns = 12
    /// Sum of every string carried by the selected prior Turn pairs:
    /// Candidate body plus Interviewer display Markdown and spoken text.
    public static let maximumPriorVisibleHistoryUTF8Bytes = 256 * 1_024

    public let sessionID: SessionID
    public let activityID: String
    public let activityPrompt: ActivityPrompt
    public let candidateTurn: CandidateTurn
    public let priorVisibleTurns: [InterviewTurn]
    public let responseTurnID: TurnID

    public init(
        sessionID: SessionID,
        activityID: String,
        activityPrompt: ActivityPrompt,
        candidateTurn: CandidateTurn,
        priorVisibleTurns: [InterviewTurn],
        responseTurnID: TurnID
    ) {
        self.sessionID = sessionID
        self.activityID = activityID
        self.activityPrompt = activityPrompt
        self.candidateTurn = candidateTurn
        self.priorVisibleTurns = priorVisibleTurns
        self.responseTurnID = responseTurnID
    }
}

/// Seam for producing one canonical Interviewer Turn response.
public protocol InterviewerRuntime: Sendable {
    func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse
}

/// Deterministic Adapter used by the tracer-bullet room and behavior tests.
public struct DeterministicInterviewerRuntime: InterviewerRuntime {
    private let response: CanonicalInterviewerResponse

    public init(response: CanonicalInterviewerResponse) {
        self.response = response
    }

    public func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse {
        response
    }
}
