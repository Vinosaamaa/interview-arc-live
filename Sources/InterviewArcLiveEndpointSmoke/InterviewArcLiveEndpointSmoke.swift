import Darwin
import Foundation
import InterviewArcLiveCore
import InterviewArcLiveVoiceAdapter

@main
struct InterviewArcLiveEndpointSmoke {
  private static let optInEnvironmentKey =
    "INTERVIEW_ARC_LIVE_RUN_ENDPOINT_SMOKE"
  private static let transcript =
    "I would make processing idempotent and retry transient failures with bounded backoff."

  @MainActor
  static func main() async {
    guard ProcessInfo.processInfo.environment[optInEnvironmentKey] == "1" else {
      fail(
        "Endpoint smoke is opt-in. Set \(optInEnvironmentKey)=1 to run it.",
        code: 64
      )
    }

    let workingDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).standardizedFileURL
    guard !isInsideRepository(workingDirectory) else {
      fail("Endpoint smoke requires a temporary non-repository working directory.", code: 65)
    }

    let stateRoot = workingDirectory.appendingPathComponent(
      "shadow-state-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let sessionID = SessionID("installed-endpoint-shadow")
    let store = FileSessionManifestStore(directoryURL: stateRoot)
    let credentialStore = LiveGroqCredentialStore()
    let productionClassifier = GroqEndpointClassifier(
      credentialReader: credentialStore
    )
    let expectedContext = SemanticEndpointContext(
      interviewerQuestion: "Describe one way to make a queue consumer resilient.",
      requestedParts: ["State the failure-handling mechanism."],
      accumulatedAnswer: transcript,
      latestSegment: transcript,
      silenceDurationMilliseconds: 0,
      specialty: "system_design",
      stage: "Installed smoke",
      explicitCue: false,
      workspaceActivity: []
    )
    let classifier = DurableProductionClassifier(
      classifier: productionClassifier,
      manifestStore: store,
      sessionID: sessionID,
      expectedContext: expectedContext
    )
    let interviewer = CountingInterviewerRuntime()
    let recorder: DeterministicSegmentRecorder
    do {
      recorder = try DeterministicSegmentRecorder()
    } catch {
      fail("Endpoint smoke failed to prepare deterministic source evidence.", code: 70)
    }
    let transcriber = DeterministicSegmentTranscriber(body: transcript)

    do {
      let prompt = try ActivityPrompt(
        specialty: .systemDesign,
        stage: "Installed smoke",
        question: "Describe one way to make a queue consumer resilient.",
        requestedParts: ["State the failure-handling mechanism."]
      )
      let coordinator = try await SegmentSpeechCoordinator.open(
        sessionID: sessionID,
        activityID: "installed-endpoint-shadow",
        activityPrompt: prompt,
        turnMode: .patientAuto,
        manifestStore: store,
        interviewerRuntime: interviewer,
        recording: recorder,
        transcriber: transcriber,
        credentialReader: credentialStore,
        semanticEndpointClassifier: classifier
      )
      _ = try await coordinator.giveCandidateFloor(
        commandID: CommandID("installed-shadow-floor")
      )
      _ = try await coordinator.beginSegment(
        commandID: CommandID("installed-shadow-begin")
      )
      let completed = try await coordinator.finishSegment(
        commandID: CommandID("installed-shadow-finish"),
        transcriptionCommandID: CommandID("installed-shadow-transcribe")
      )

      let persisted = try await store.load(sessionID: sessionID)
      let classifierCalls = await classifier.invocationCount()
      let durableAtEntry = await classifier.authorizationWasDurableAtEntry()
      let transcriberCalls = await transcriber.invocationCount()
      let interviewerCalls = await interviewer.invocationCount()
      guard
        completed.turnMode == .patientAuto,
        completed.phase == .candidateFloor,
        completed.turns.isEmpty,
        completed.segments.count == 1,
        completed.segments.first?.selectedCandidate?.body == transcript,
        completed.endpointEvaluations.count == 1,
        completed.endpointEvaluations.first?.lifecycle == .proposalStored,
        completed.endpointEvaluations.first?.proposal != nil,
        completed.endpointEvaluations.first?.failure == nil,
        persisted?.endpointEvaluations == completed.endpointEvaluations,
        persisted?.phase == .candidateFloor,
        persisted?.turns.isEmpty == true,
        classifierCalls == 1,
        durableAtEntry,
        recorder.beginCount == 1,
        recorder.finishCount == 1,
        transcriberCalls == 1,
        interviewerCalls == 0
      else {
        if completed.endpointEvaluations.first?.failure?.reason == .missingCredential {
          fail(
            "Endpoint smoke failed: Interview Arc Live has no readable Groq credential.",
            code: 70
          )
        }
        fail("Endpoint smoke failed: the Shadow invariants were not satisfied.", code: 70)
      }
      print("Installed Patient Auto Groq endpoint shadow smoke passed.")
    } catch SegmentSpeechCoordinatorError.credentialUnavailable {
      fail(
        "Endpoint smoke failed: Interview Arc Live has no readable Groq credential.",
        code: 70
      )
    } catch {
      fail("Endpoint smoke failed before durable Shadow verification completed.", code: 70)
    }
  }

  private static func isInsideRepository(_ directory: URL) -> Bool {
    var current = directory.resolvingSymlinksInPath().standardizedFileURL
    while current.path != "/" {
      if FileManager.default.fileExists(
        atPath: current.appendingPathComponent(".git").path
      ) {
        return true
      }
      current.deleteLastPathComponent()
    }
    return false
  }

  private static func fail(_ message: String, code: Int32) -> Never {
    if let data = "\(message)\n".data(using: .utf8) {
      try? FileHandle.standardError.write(contentsOf: data)
    }
    Darwin.exit(code)
  }
}

private actor DurableProductionClassifier: SemanticEndpointClassifying {
  private let classifier: GroqEndpointClassifier
  private let manifestStore: FileSessionManifestStore
  private let sessionID: SessionID
  private let expectedContext: SemanticEndpointContext
  private var calls = 0
  private var authorizationDurableAtEntry = false

  init(
    classifier: GroqEndpointClassifier,
    manifestStore: FileSessionManifestStore,
    sessionID: SessionID,
    expectedContext: SemanticEndpointContext
  ) {
    self.classifier = classifier
    self.manifestStore = manifestStore
    self.sessionID = sessionID
    self.expectedContext = expectedContext
  }

  func classify(
    _ context: SemanticEndpointContext
  ) async throws -> SemanticEndpointProposal {
    calls += 1
    let manifest = try await manifestStore.load(sessionID: sessionID)
    authorizationDurableAtEntry =
      manifest?.endpointEvaluations.last?.lifecycle == .authorized
    guard authorizationDurableAtEntry, context == expectedContext else {
      throw EndpointSmokeAssertionError.unexpectedClassifierEntry
    }
    return try await classifier.classify(context)
  }

  func invocationCount() -> Int { calls }
  func authorizationWasDurableAtEntry() -> Bool { authorizationDurableAtEntry }
}

@MainActor
private final class DeterministicSegmentRecorder: SegmentRecording {
  private let capture: CapturedAudioSegment
  private var unexpectedTerminationHandler: (@MainActor @Sendable () -> Void)?
  private(set) var beginCount = 0
  private(set) var finishCount = 0

  init() throws {
    capture = CapturedAudioSegment(
      audioIdentity: try SegmentAudioIdentity(
        validating: "installed-shadow-segment.m4a"
      ),
      startedAtMilliseconds: 1_000,
      endedAtMilliseconds: 2_000,
      durationMilliseconds: 1_000,
      decodedDurationMilliseconds: 1_000,
      byteCount: 4_096,
      isPlayable: true,
      isPartial: false
    )
  }

  func setUnexpectedTerminationHandler(
    _ handler: (@MainActor @Sendable () -> Void)?
  ) {
    unexpectedTerminationHandler = handler
  }

  func beginCapture(_ request: SegmentCaptureRequest) async throws {
    beginCount += 1
  }

  func finishCapture() async throws -> CapturedAudioSegment {
    finishCount += 1
    return capture
  }

  func recoverCapture(
    _ request: SegmentCaptureRequest
  ) async throws -> CapturedAudioSegment? {
    nil
  }

  func playbackURL(
    sessionID: SessionID,
    audioIdentity: SegmentAudioIdentity
  ) async throws -> URL {
    URL(fileURLWithPath: audioIdentity.fileName)
  }
}

private actor DeterministicSegmentTranscriber: SegmentTranscribing {
  private let body: String
  private var calls = 0

  init(body: String) {
    self.body = body
  }

  func transcribe(
    _ request: SegmentTranscriptionRequest,
    credential: String
  ) -> SegmentTranscriptionResult {
    calls += 1
    return SegmentTranscriptionResult(body: body, quality: .verified)
  }

  func invocationCount() -> Int { calls }
}

private actor CountingInterviewerRuntime: InterviewerRuntime {
  private var calls = 0

  func respond(
    to request: InterviewerRequest
  ) -> CanonicalInterviewerResponse {
    calls += 1
    return CanonicalInterviewerResponse(
      displayMarkdown: "This response must remain unreachable.",
      spokenText: "This response must remain unreachable."
    )
  }

  func invocationCount() -> Int { calls }
}

private enum EndpointSmokeAssertionError: Error {
  case unexpectedClassifierEntry
}
