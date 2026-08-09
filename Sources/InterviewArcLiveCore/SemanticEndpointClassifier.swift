import Foundation

/// Classifies whether the current Candidate Turn appears ready for Hand off.
///
/// A proposal is evidence for turn-taking policy. It never commits a turn or
/// mutates an Interview Room Session by itself.
public protocol SemanticEndpointClassifying: Sendable {
  func classify(_ context: SemanticEndpointContext) async throws -> SemanticEndpointProposal
}

public struct SemanticEndpointContext: Codable, Sendable, Equatable {
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

public struct SemanticEndpointWorkspaceActivity: Codable, Sendable, Equatable {
  public let kind: String
  public let millisecondsAgo: Int
  public let summary: String

  public init(kind: String, millisecondsAgo: Int, summary: String) {
    self.kind = kind
    self.millisecondsAgo = millisecondsAgo
    self.summary = summary
  }
}

public enum SemanticEndpointDecision: String, Codable, Sendable, Equatable, CaseIterable {
  case likelyContinue = "likely_continue"
  case likelyEnd = "likely_end"
  case ambiguous
}

public enum SemanticEndpointReasonCode: String, Codable, Sendable, Equatable, CaseIterable {
  case explicitHandoffCue = "explicit_handoff_cue"
  case answerResolvesQuestion = "answer_resolves_question"
  case unfinishedThought = "unfinished_thought"
  case requestedPartUnanswered = "requested_part_unanswered"
  case recentWorkspaceActivity = "recent_workspace_activity"
  case insufficientEvidence = "insufficient_evidence"
}

public struct SemanticEndpointProposal: Codable, Sendable, Equatable {
  public let decision: SemanticEndpointDecision
  public let reasonCode: SemanticEndpointReasonCode

  public init(decision: SemanticEndpointDecision, reasonCode: SemanticEndpointReasonCode) {
    self.decision = decision
    self.reasonCode = reasonCode
  }
}

public struct EndpointEvaluationID:
  RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public enum EndpointEvaluationLifecycle: String, Codable, Sendable, Equatable {
  case authorized
  case proposalStored = "proposal_stored"
  case failed
}

/// Bounded failure categories safe to persist and present. Provider response
/// bodies, request context, credentials, and private paths never cross this
/// Interface.
public enum EndpointEvaluationFailureReason: String, Codable, Sendable, Equatable {
  case missingCredential = "missing_credential"
  case contextRejected = "context_rejected"
  case transportFailure = "transport_failure"
  case providerRejected = "provider_rejected"
  case invalidResponse = "invalid_response"
  case interrupted
}

public struct EndpointEvaluationFailure: Codable, Sendable, Equatable {
  public let reason: EndpointEvaluationFailureReason
  public let providerStatusCode: Int?

  public init(
    reason: EndpointEvaluationFailureReason,
    providerStatusCode: Int? = nil
  ) {
    self.reason = reason
    self.providerStatusCode = providerStatusCode
  }
}

public enum EndpointEvaluationOutcome: Codable, Sendable, Equatable {
  case proposal(SemanticEndpointProposal)
  case failed(EndpointEvaluationFailure)
}

/// One durably authorized semantic-classifier request. It retains only stable
/// evidence identities and a fingerprint; the prompt and transcript bodies
/// remain canonical elsewhere in the Session Manifest.
public struct EndpointEvaluation: Codable, Sendable, Equatable {
  public let id: EndpointEvaluationID
  public let authorizationCommandID: CommandID
  public let triggerSegmentID: SegmentID
  public let selectedCandidateIDs: [TranscriptCandidateID]
  public let questionTurnID: TurnID?
  public let contextFingerprint: String
  public let lifecycle: EndpointEvaluationLifecycle
  public let proposal: SemanticEndpointProposal?
  public let failure: EndpointEvaluationFailure?

  public init(
    id: EndpointEvaluationID,
    authorizationCommandID: CommandID,
    triggerSegmentID: SegmentID,
    selectedCandidateIDs: [TranscriptCandidateID],
    questionTurnID: TurnID?,
    contextFingerprint: String,
    lifecycle: EndpointEvaluationLifecycle,
    proposal: SemanticEndpointProposal? = nil,
    failure: EndpointEvaluationFailure? = nil
  ) {
    self.id = id
    self.authorizationCommandID = authorizationCommandID
    self.triggerSegmentID = triggerSegmentID
    self.selectedCandidateIDs = selectedCandidateIDs
    self.questionTurnID = questionTurnID
    self.contextFingerprint = contextFingerprint
    self.lifecycle = lifecycle
    self.proposal = proposal
    self.failure = failure
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
