import Foundation
import XCTest

@testable import InterviewArcLiveCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@MainActor
final class GroqEndpointClassifierTests: XCTestCase {
  func testRequestUsesGPTOSSAndPreservesExactBoundedContext() async throws {
    let transport = RecordingGroqTransport(
      statusCode: 200,
      body: responseBody(decision: "likely_continue", reason: "requested_part_unanswered")
    )
    let classifier = GroqEndpointClassifier(
      credentialReader: FixedEndpointCredentialReader("private-test-key"),
      transport: transport
    )
    let context = SemanticEndpointContext(
      interviewerQuestion: "How are you, and why did you choose BFS?",
      requestedParts: ["Describe how you are", "Explain the BFS choice"],
      accumulatedAnswer: "I'm fine, thank you.",
      latestSegment: "I'm fine, thank you.",
      silenceDurationMilliseconds: 1_750,
      specialty: "coding",
      stage: "candidate_floor",
      explicitCue: false,
      workspaceActivity: [
        .init(kind: "code_edit", millisecondsAgo: 320, summary: "Changed the queue initialization.")
      ]
    )

    let proposal = try await classifier.classify(context)

    XCTAssertEqual(
      proposal,
      SemanticEndpointProposal(
        decision: .likelyContinue,
        reasonCode: .requestedPartUnanswered
      )
    )

    let recordedRequest = await transport.recordedRequest()
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-test-key")

    let bodyData = try XCTUnwrap(request.httpBody)
    let bodyString = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
    XCTAssertFalse(bodyString.contains("private-test-key"))

    let body = try jsonDictionary(bodyData)
    XCTAssertEqual(body["model"] as? String, "openai/gpt-oss-20b")
    XCTAssertEqual(body["temperature"] as? Int, 0)
    XCTAssertEqual(body["reasoning_effort"] as? String, "low")
    XCTAssertEqual(body["max_completion_tokens"] as? Int, 256)

    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    let userMessage = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
    let contextJSON = try XCTUnwrap(userMessage["content"] as? String)
    let requestContext = try jsonDictionary(Data(contextJSON.utf8))

    XCTAssertEqual(requestContext["interviewer_question"] as? String, context.interviewerQuestion)
    XCTAssertEqual(requestContext["requested_parts"] as? [String], context.requestedParts)
    XCTAssertEqual(requestContext["accumulated_answer"] as? String, context.accumulatedAnswer)
    XCTAssertEqual(requestContext["latest_segment"] as? String, context.latestSegment)
    XCTAssertEqual(
      requestContext["silence_duration_ms"] as? Int, context.silenceDurationMilliseconds)
    XCTAssertEqual(requestContext["specialty"] as? String, context.specialty)
    XCTAssertEqual(requestContext["stage"] as? String, context.stage)
    XCTAssertEqual(requestContext["explicit_cue"] as? Bool, context.explicitCue)

    let activity = try XCTUnwrap(requestContext["workspace_activity"] as? [[String: Any]])
    XCTAssertEqual(activity.first?["kind"] as? String, "code_edit")
    XCTAssertEqual(activity.first?["milliseconds_ago"] as? Int, 320)
    XCTAssertEqual(activity.first?["summary"] as? String, "Changed the queue initialization.")

    let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
    let schemaEnvelope = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
    XCTAssertEqual(schemaEnvelope["strict"] as? Bool, true)
    let schema = try XCTUnwrap(schemaEnvelope["schema"] as? [String: Any])
    let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
    XCTAssertEqual(Set(properties.keys), ["decision", "reason_code"])
    XCTAssertNil(properties["confidence"])
  }

  func testStrictlyDecodesEverySupportedDecision() async throws {
    let cases: [(String, String, SemanticEndpointProposal)] = [
      (
        "likely_continue",
        "unfinished_thought",
        .init(decision: .likelyContinue, reasonCode: .unfinishedThought)
      ),
      (
        "likely_end",
        "answer_resolves_question",
        .init(decision: .likelyEnd, reasonCode: .answerResolvesQuestion)
      ),
      (
        "ambiguous",
        "insufficient_evidence",
        .init(decision: .ambiguous, reasonCode: .insufficientEvidence)
      ),
    ]

    for (decision, reason, expected) in cases {
      let transport = RecordingGroqTransport(
        statusCode: 200,
        body: responseBody(decision: decision, reason: reason)
      )
      let classifier = GroqEndpointClassifier(
        credentialReader: FixedEndpointCredentialReader("test-key"),
        transport: transport
      )
      let actual = try await classifier.classify(validContext)
      XCTAssertEqual(actual, expected)
    }
  }

  func testRejectsAdditionalConfidenceField() async throws {
    let content = """
      {"decision":"likely_end","reason_code":"answer_resolves_question","confidence":0.99}
      """
    let transport = RecordingGroqTransport(
      statusCode: 200,
      body: chatResponse(content: content)
    )
    let classifier = GroqEndpointClassifier(
      credentialReader: FixedEndpointCredentialReader("test-key"),
      transport: transport
    )

    await assertClassifierError(.invalidClassification) {
      try await classifier.classify(validContext)
    }
  }

  func testRejectsUnknownClassificationValue() async throws {
    let transport = RecordingGroqTransport(
      statusCode: 200,
      body: responseBody(decision: "done", reason: "answer_resolves_question")
    )
    let classifier = GroqEndpointClassifier(
      credentialReader: FixedEndpointCredentialReader("test-key"),
      transport: transport
    )

    await assertClassifierError(.invalidClassification) {
      try await classifier.classify(validContext)
    }
  }

  func testRejectsDecisionAndReasonMismatch() async throws {
    let transport = RecordingGroqTransport(
      statusCode: 200,
      body: responseBody(decision: "likely_end", reason: "unfinished_thought")
    )
    let classifier = GroqEndpointClassifier(
      credentialReader: FixedEndpointCredentialReader("test-key"),
      transport: transport
    )

    await assertClassifierError(.invalidClassification) {
      try await classifier.classify(validContext)
    }
  }

  func testOversizedExactQuestionFailsBeforeTransport() async throws {
    let transport = RecordingGroqTransport(
      statusCode: 200,
      body: responseBody(decision: "ambiguous", reason: "insufficient_evidence")
    )
    let classifier = GroqEndpointClassifier(
      credentialReader: FixedEndpointCredentialReader("test-key"),
      transport: transport
    )
    let context = SemanticEndpointContext(
      interviewerQuestion: String(repeating: "q", count: 16 * 1_024 + 1),
      requestedParts: [],
      accumulatedAnswer: "An answer.",
      latestSegment: "An answer.",
      silenceDurationMilliseconds: 1_000,
      specialty: "behavioral",
      stage: "candidate_floor",
      explicitCue: false,
      workspaceActivity: []
    )

    await assertClassifierError(.contextLimitExceeded(.interviewerQuestion)) {
      try await classifier.classify(context)
    }
    let recordedRequest = await transport.recordedRequest()
    XCTAssertNil(recordedRequest)
  }

  func testTransportAndProviderErrorsExposeNoPayloadOrCredential() async throws {
    let failingTransport = RecordingGroqTransport(failure: true)
    let transportClassifier = GroqEndpointClassifier(
      credentialReader: FixedEndpointCredentialReader("must-never-appear"),
      transport: failingTransport
    )

    await assertClassifierError(.transportFailure) {
      try await transportClassifier.classify(validContext)
    }

    let rejectedTransport = RecordingGroqTransport(
      statusCode: 429,
      body: Data("provider diagnostic containing request data".utf8)
    )
    let rejectedClassifier = GroqEndpointClassifier(
      credentialReader: FixedEndpointCredentialReader("must-never-appear"),
      transport: rejectedTransport
    )
    await assertClassifierError(.rejected(statusCode: 429)) {
      try await rejectedClassifier.classify(validContext)
    }
  }

  func testReadsTheCurrentCredentialForEveryRequest() async throws {
    let credentialReader = RotatingEndpointCredentialReader([
      "first-private-key",
      "second-private-key",
    ])
    let transport = RecordingGroqTransport(
      statusCode: 200,
      body: responseBody(decision: "ambiguous", reason: "insufficient_evidence")
    )
    let classifier = GroqEndpointClassifier(
      credentialReader: credentialReader,
      transport: transport
    )

    _ = try await classifier.classify(validContext)
    _ = try await classifier.classify(validContext)

    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(
      requests[0].value(forHTTPHeaderField: "Authorization"),
      "Bearer first-private-key"
    )
    XCTAssertEqual(
      requests[1].value(forHTTPHeaderField: "Authorization"),
      "Bearer second-private-key"
    )
    let credentialReadCount = await credentialReader.readCount()
    XCTAssertEqual(credentialReadCount, 2)
  }

  func testMissingOrUnreadableCurrentCredentialFailsBeforeTransport() async {
    let transport = RecordingGroqTransport()
    let missingClassifier = GroqEndpointClassifier(
      credentialReader: FixedEndpointCredentialReader("  \n"),
      transport: transport
    )
    await assertClassifierError(.missingCredential) {
      try await missingClassifier.classify(validContext)
    }

    let unreadableClassifier = GroqEndpointClassifier(
      credentialReader: FailingEndpointCredentialReader(),
      transport: transport
    )
    await assertClassifierError(.missingCredential) {
      try await unreadableClassifier.classify(validContext)
    }

    let requests = await transport.recordedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testDeterministicAdapterUsesTheSameClassifierSeam() async throws {
    let expected = SemanticEndpointProposal(
      decision: .ambiguous,
      reasonCode: .insufficientEvidence
    )
    let classifier: any SemanticEndpointClassifying =
      DeterministicSemanticEndpointClassifier(proposal: expected)

    let proposal = try await classifier.classify(validContext)

    XCTAssertEqual(proposal, expected)
  }

  private var validContext: SemanticEndpointContext {
    SemanticEndpointContext(
      interviewerQuestion: "Explain your approach.",
      requestedParts: ["State the invariant", "Analyze complexity"],
      accumulatedAnswer: "The queue stores the current frontier.",
      latestSegment: "The queue stores the current frontier.",
      silenceDurationMilliseconds: 1_200,
      specialty: "coding",
      stage: "candidate_floor",
      explicitCue: false,
      workspaceActivity: []
    )
  }

  private func responseBody(decision: String, reason: String) -> Data {
    chatResponse(content: "{\"decision\":\"\(decision)\",\"reason_code\":\"\(reason)\"}")
  }

  private func chatResponse(content: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "choices": [
        ["message": ["content": content]]
      ]
    ])
  }

  private func jsonDictionary(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func assertClassifierError(
    _ expected: GroqEndpointClassifierError,
    operation: () async throws -> SemanticEndpointProposal
  ) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(expected)")
    } catch let error as GroqEndpointClassifierError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error type: \(type(of: error))")
    }
  }
}

private actor RecordingGroqTransport: GroqEndpointTransport {
  private let statusCode: Int
  private let body: Data
  private let failure: Bool
  private var requests: [URLRequest] = []

  init(statusCode: Int = 200, body: Data = Data(), failure: Bool = false) {
    self.statusCode = statusCode
    self.body = body
    self.failure = failure
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if failure {
      throw RecordingTransportError.failure
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    return (body, response)
  }

  func recordedRequest() -> URLRequest? {
    requests.last
  }

  func recordedRequests() -> [URLRequest] {
    requests
  }
}

private struct FixedEndpointCredentialReader: GroqCredentialReading {
  private let value: String

  init(_ value: String) {
    self.value = value
  }

  func readGroqCredential() -> String {
    value
  }
}

private actor RotatingEndpointCredentialReader: GroqCredentialReading {
  private let values: [String]
  private var index = 0

  init(_ values: [String]) {
    self.values = values
  }

  func readGroqCredential() throws -> String {
    guard index < values.count else {
      throw EndpointCredentialReaderError.unavailable
    }
    defer { index += 1 }
    return values[index]
  }

  func readCount() -> Int {
    index
  }
}

private struct FailingEndpointCredentialReader: GroqCredentialReading {
  func readGroqCredential() throws -> String {
    throw EndpointCredentialReaderError.unavailable
  }
}

private enum EndpointCredentialReaderError: Error {
  case unavailable
}

private enum RecordingTransportError: Error {
  case failure
}
