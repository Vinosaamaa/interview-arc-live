import Foundation

/// Classifies whether the current Candidate Turn appears ready for Hand off.
///
/// A proposal is evidence for turn-taking policy. It never commits a turn or
/// mutates an Interview Room Session by itself.
public protocol SemanticEndpointClassifying: Sendable {
  func classify(_ context: SemanticEndpointContext) async throws -> SemanticEndpointProposal
}

public struct SemanticEndpointContext: Sendable, Equatable {
  public let interviewerQuestion: String
  public let requestedParts: [String]
  public let accumulatedAnswer: String
  public let latestSegment: String
  public let silenceDurationMilliseconds: Int
  public let specialty: String
  public let stage: String
  public let explicitCue: Bool
  public let workspaceActivity: [SemanticEndpointWorkspaceActivity]

  public init(
    interviewerQuestion: String,
    requestedParts: [String],
    accumulatedAnswer: String,
    latestSegment: String,
    silenceDurationMilliseconds: Int,
    specialty: String,
    stage: String,
    explicitCue: Bool,
    workspaceActivity: [SemanticEndpointWorkspaceActivity]
  ) {
    self.interviewerQuestion = interviewerQuestion
    self.requestedParts = requestedParts
    self.accumulatedAnswer = accumulatedAnswer
    self.latestSegment = latestSegment
    self.silenceDurationMilliseconds = silenceDurationMilliseconds
    self.specialty = specialty
    self.stage = stage
    self.explicitCue = explicitCue
    self.workspaceActivity = workspaceActivity
  }
}

public struct SemanticEndpointWorkspaceActivity: Sendable, Equatable {
  public let kind: String
  public let millisecondsAgo: Int
  public let summary: String

  public init(kind: String, millisecondsAgo: Int, summary: String) {
    self.kind = kind
    self.millisecondsAgo = millisecondsAgo
    self.summary = summary
  }
}

public enum SemanticEndpointDecision: String, Sendable, Equatable, CaseIterable {
  case likelyContinue = "likely_continue"
  case likelyEnd = "likely_end"
  case ambiguous
}

public enum SemanticEndpointReasonCode: String, Sendable, Equatable, CaseIterable {
  case explicitHandoffCue = "explicit_handoff_cue"
  case answerResolvesQuestion = "answer_resolves_question"
  case unfinishedThought = "unfinished_thought"
  case requestedPartUnanswered = "requested_part_unanswered"
  case recentWorkspaceActivity = "recent_workspace_activity"
  case insufficientEvidence = "insufficient_evidence"
}

public struct SemanticEndpointProposal: Sendable, Equatable {
  public let decision: SemanticEndpointDecision
  public let reasonCode: SemanticEndpointReasonCode

  public init(decision: SemanticEndpointDecision, reasonCode: SemanticEndpointReasonCode) {
    self.decision = decision
    self.reasonCode = reasonCode
  }
}

/// A deterministic Adapter used by fixtures and tests at the same Seam as the
/// production Groq Adapter.
public struct DeterministicSemanticEndpointClassifier: SemanticEndpointClassifying {
  private let proposal: SemanticEndpointProposal

  public init(proposal: SemanticEndpointProposal) {
    self.proposal = proposal
  }

  public func classify(_ context: SemanticEndpointContext) async throws -> SemanticEndpointProposal
  {
    proposal
  }
}
