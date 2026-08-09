import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public protocol GroqEndpointTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production HTTP Adapter. Its ephemeral session does not persist model
/// payloads, cookies, or response data to disk.
public struct URLSessionGroqEndpointTransport: GroqEndpointTransport {
  private let session: URLSession

  public init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw GroqEndpointClassifierError.invalidHTTPResponse
    }
    return (data, response)
  }
}

public enum GroqEndpointContextField: String, Sendable, Equatable {
  case interviewerQuestion = "interviewer_question"
  case requestedParts = "requested_parts"
  case accumulatedAnswer = "accumulated_answer"
  case latestSegment = "latest_segment"
  case silenceDuration = "silence_duration_ms"
  case specialty
  case stage
  case workspaceActivity = "workspace_activity"
  case totalContext = "total_context"
}

/// Errors intentionally contain no request content, provider response body, or
/// credential material.
public enum GroqEndpointClassifierError: Error, Sendable, Equatable {
  case missingCredential
  case invalidContext(GroqEndpointContextField)
  case contextLimitExceeded(GroqEndpointContextField)
  case transportFailure
  case invalidHTTPResponse
  case rejected(statusCode: Int)
  case malformedResponse
  case invalidClassification
}

/// Groq `openai/gpt-oss-20b` Adapter for the semantic endpoint Seam.
///
/// The Adapter accepts only bounded, complete context. It never truncates the
/// interviewer question, requested parts, accumulated answer, or latest
/// Segment, so every accepted request preserves those values exactly.
public struct GroqEndpointClassifier: SemanticEndpointClassifying {
  private static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
  private static let model = "openai/gpt-oss-20b"
  private static let maximumTotalContextBytes = 96 * 1_024
  private static let maximumQuestionBytes = 16 * 1_024
  private static let maximumRequestedParts = 24
  private static let maximumRequestedPartBytes = 4 * 1_024
  private static let maximumAccumulatedAnswerBytes = 64 * 1_024
  private static let maximumLatestSegmentBytes = 16 * 1_024
  private static let maximumLabelBytes = 256
  private static let maximumWorkspaceEvents = 24
  private static let maximumWorkspaceSummaryBytes = 2 * 1_024
  private static let maximumSilenceMilliseconds = 10 * 60 * 1_000
  private static let maximumResponseBytes = 64 * 1_024

  private let apiKey: String
  private let transport: any GroqEndpointTransport

  public init(
    apiKey: String,
    transport: any GroqEndpointTransport = URLSessionGroqEndpointTransport()
  ) {
    self.apiKey = apiKey
    self.transport = transport
  }

  public func classify(_ context: SemanticEndpointContext) async throws -> SemanticEndpointProposal
  {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GroqEndpointClassifierError.missingCredential
    }

    let request: URLRequest
    do {
      request = try makeRequest(context)
    } catch let error as GroqEndpointClassifierError {
      throw error
    } catch {
      throw GroqEndpointClassifierError.invalidContext(.totalContext)
    }

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch let error as GroqEndpointClassifierError {
      throw error
    } catch {
      throw GroqEndpointClassifierError.transportFailure
    }

    guard (200..<300).contains(response.statusCode) else {
      throw GroqEndpointClassifierError.rejected(statusCode: response.statusCode)
    }
    guard data.count <= Self.maximumResponseBytes else {
      throw GroqEndpointClassifierError.malformedResponse
    }

    return try decodeProposal(from: data)
  }

  private func makeRequest(_ context: SemanticEndpointContext) throws -> URLRequest {
    try validate(context)

    let endpointContext = EndpointContextPayload(
      interviewerQuestion: context.interviewerQuestion,
      requestedParts: context.requestedParts,
      accumulatedAnswer: context.accumulatedAnswer,
      latestSegment: context.latestSegment,
      silenceDurationMilliseconds: context.silenceDurationMilliseconds,
      specialty: context.specialty,
      stage: context.stage,
      explicitCue: context.explicitCue,
      workspaceActivity: context.workspaceActivity.map {
        WorkspaceActivityPayload(
          kind: $0.kind,
          millisecondsAgo: $0.millisecondsAgo,
          summary: $0.summary
        )
      }
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let contextData = try encoder.encode(endpointContext)
    guard contextData.count <= Self.maximumTotalContextBytes else {
      throw GroqEndpointClassifierError.contextLimitExceeded(.totalContext)
    }
    guard let contextJSON = String(data: contextData, encoding: .utf8) else {
      throw GroqEndpointClassifierError.invalidContext(.totalContext)
    }

    let body = ChatCompletionRequest(
      model: Self.model,
      temperature: 0,
      maxCompletionTokens: 256,
      reasoningEffort: "low",
      messages: [
        .init(role: "system", content: Self.systemInstruction),
        .init(role: "user", content: contextJSON),
      ],
      responseFormat: .semanticEndpoint
    )

    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try encoder.encode(body)
    return request
  }

  private func validate(_ context: SemanticEndpointContext) throws {
    try requireNonempty(context.interviewerQuestion, field: .interviewerQuestion)
    try requireNonempty(context.accumulatedAnswer, field: .accumulatedAnswer)
    try requireNonempty(context.latestSegment, field: .latestSegment)
    try requireNonempty(context.specialty, field: .specialty)
    try requireNonempty(context.stage, field: .stage)

    try requireByteCount(
      context.interviewerQuestion,
      atMost: Self.maximumQuestionBytes,
      field: .interviewerQuestion
    )
    guard context.requestedParts.count <= Self.maximumRequestedParts else {
      throw GroqEndpointClassifierError.contextLimitExceeded(.requestedParts)
    }
    for part in context.requestedParts {
      try requireNonempty(part, field: .requestedParts)
      try requireByteCount(part, atMost: Self.maximumRequestedPartBytes, field: .requestedParts)
    }
    try requireByteCount(
      context.accumulatedAnswer,
      atMost: Self.maximumAccumulatedAnswerBytes,
      field: .accumulatedAnswer
    )
    try requireByteCount(
      context.latestSegment,
      atMost: Self.maximumLatestSegmentBytes,
      field: .latestSegment
    )
    try requireByteCount(context.specialty, atMost: Self.maximumLabelBytes, field: .specialty)
    try requireByteCount(context.stage, atMost: Self.maximumLabelBytes, field: .stage)

    guard
      context.silenceDurationMilliseconds >= 0,
      context.silenceDurationMilliseconds <= Self.maximumSilenceMilliseconds
    else {
      throw GroqEndpointClassifierError.invalidContext(.silenceDuration)
    }

    guard context.workspaceActivity.count <= Self.maximumWorkspaceEvents else {
      throw GroqEndpointClassifierError.contextLimitExceeded(.workspaceActivity)
    }
    for activity in context.workspaceActivity {
      try requireNonempty(activity.kind, field: .workspaceActivity)
      try requireByteCount(activity.kind, atMost: Self.maximumLabelBytes, field: .workspaceActivity)
      guard activity.millisecondsAgo >= 0 else {
        throw GroqEndpointClassifierError.invalidContext(.workspaceActivity)
      }
      try requireByteCount(
        activity.summary,
        atMost: Self.maximumWorkspaceSummaryBytes,
        field: .workspaceActivity
      )
    }
  }

  private func requireNonempty(_ value: String, field: GroqEndpointContextField) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GroqEndpointClassifierError.invalidContext(field)
    }
  }

  private func requireByteCount(
    _ value: String,
    atMost limit: Int,
    field: GroqEndpointContextField
  ) throws {
    guard value.utf8.count <= limit else {
      throw GroqEndpointClassifierError.contextLimitExceeded(field)
    }
  }

  private func decodeProposal(from data: Data) throws -> SemanticEndpointProposal {
    let response: ChatCompletionResponse
    do {
      response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    } catch {
      throw GroqEndpointClassifierError.malformedResponse
    }

    guard
      response.choices.count == 1,
      let content = response.choices.first?.message.content,
      let contentData = content.data(using: .utf8)
    else {
      throw GroqEndpointClassifierError.malformedResponse
    }

    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: contentData)
    } catch {
      throw GroqEndpointClassifierError.invalidClassification
    }
    guard let dictionary = object as? [String: Any] else {
      throw GroqEndpointClassifierError.invalidClassification
    }
    guard Set(dictionary.keys) == ["decision", "reason_code"] else {
      throw GroqEndpointClassifierError.invalidClassification
    }
    guard
      let decisionValue = dictionary["decision"] as? String,
      let decision = SemanticEndpointDecision(rawValue: decisionValue),
      let reasonValue = dictionary["reason_code"] as? String,
      let reason = SemanticEndpointReasonCode(rawValue: reasonValue),
      Self.isConsistent(decision: decision, reason: reason)
    else {
      throw GroqEndpointClassifierError.invalidClassification
    }

    return SemanticEndpointProposal(decision: decision, reasonCode: reason)
  }

  private static let systemInstruction = """
    You classify whether a candidate has finished one logical technical-interview answer. Use only the supplied JSON context. Silence alone never ends the Candidate Turn. Return likely_continue when a thought or requested part remains unfinished, or recent coding, drawing, or note activity indicates continued work. Return likely_end only when the answer resolves the exact question or an explicit Hand off cue is present. Return ambiguous when the evidence is insufficient. Never invent omitted speech. Return only the required JSON object; do not include confidence, prose, or additional keys.
    """

  private static func isConsistent(
    decision: SemanticEndpointDecision,
    reason: SemanticEndpointReasonCode
  ) -> Bool {
    switch reason {
    case .explicitHandoffCue, .answerResolvesQuestion:
      decision == .likelyEnd
    case .unfinishedThought, .requestedPartUnanswered, .recentWorkspaceActivity:
      decision == .likelyContinue
    case .insufficientEvidence:
      decision == .ambiguous
    }
  }
}

private struct EndpointContextPayload: Encodable, Sendable {
  let interviewerQuestion: String
  let requestedParts: [String]
  let accumulatedAnswer: String
  let latestSegment: String
  let silenceDurationMilliseconds: Int
  let specialty: String
  let stage: String
  let explicitCue: Bool
  let workspaceActivity: [WorkspaceActivityPayload]

  enum CodingKeys: String, CodingKey {
    case interviewerQuestion = "interviewer_question"
    case requestedParts = "requested_parts"
    case accumulatedAnswer = "accumulated_answer"
    case latestSegment = "latest_segment"
    case silenceDurationMilliseconds = "silence_duration_ms"
    case specialty
    case stage
    case explicitCue = "explicit_cue"
    case workspaceActivity = "workspace_activity"
  }
}

private struct WorkspaceActivityPayload: Encodable, Sendable {
  let kind: String
  let millisecondsAgo: Int
  let summary: String

  enum CodingKeys: String, CodingKey {
    case kind
    case millisecondsAgo = "milliseconds_ago"
    case summary
  }
}

private struct ChatCompletionRequest: Encodable, Sendable {
  let model: String
  let temperature: Int
  let maxCompletionTokens: Int
  let reasoningEffort: String
  let messages: [Message]
  let responseFormat: ResponseFormat

  enum CodingKeys: String, CodingKey {
    case model
    case temperature
    case maxCompletionTokens = "max_completion_tokens"
    case reasoningEffort = "reasoning_effort"
    case messages
    case responseFormat = "response_format"
  }

  struct Message: Encodable, Sendable {
    let role: String
    let content: String
  }

  struct ResponseFormat: Encodable, Sendable {
    let type: String
    let jsonSchema: JSONSchemaEnvelope

    enum CodingKeys: String, CodingKey {
      case type
      case jsonSchema = "json_schema"
    }

    static let semanticEndpoint = ResponseFormat(
      type: "json_schema",
      jsonSchema: JSONSchemaEnvelope(
        name: "semantic_endpoint_proposal",
        strict: true,
        schema: JSONSchema(
          type: "object",
          properties: [
            "decision": .init(
              type: "string",
              enumValues: SemanticEndpointDecision.allCases.map(\.rawValue)
            ),
            "reason_code": .init(
              type: "string",
              enumValues: SemanticEndpointReasonCode.allCases.map(\.rawValue)
            ),
          ],
          required: ["decision", "reason_code"],
          additionalProperties: false
        )
      )
    )
  }

  struct JSONSchemaEnvelope: Encodable, Sendable {
    let name: String
    let strict: Bool
    let schema: JSONSchema
  }

  struct JSONSchema: Encodable, Sendable {
    let type: String
    let properties: [String: JSONProperty]
    let required: [String]
    let additionalProperties: Bool

    enum CodingKeys: String, CodingKey {
      case type
      case properties
      case required
      case additionalProperties = "additionalProperties"
    }
  }

  struct JSONProperty: Encodable, Sendable {
    let type: String
    let enumValues: [String]

    enum CodingKeys: String, CodingKey {
      case type
      case enumValues = "enum"
    }
  }
}

private struct ChatCompletionResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: Message
  }

  struct Message: Decodable {
    let content: String?
  }
}
