import Foundation

/// Input presented to the Interviewer Runtime Seam after an explicit Hand off.
public struct InterviewerRequest: Sendable, Equatable {
    public let sessionID: SessionID
    public let activityID: String
    public let candidateTurn: CandidateTurn
    public let precedingTurns: [InterviewTurn]

    public init(
        sessionID: SessionID,
        activityID: String,
        candidateTurn: CandidateTurn,
        precedingTurns: [InterviewTurn]
    ) {
        self.sessionID = sessionID
        self.activityID = activityID
        self.candidateTurn = candidateTurn
        self.precedingTurns = precedingTurns
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
