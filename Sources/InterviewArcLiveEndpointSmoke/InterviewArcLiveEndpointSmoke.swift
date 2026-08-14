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
      "patient-auto-state-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let sessionID = SessionID("installed-patient-auto")
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
        activityID: "installed-patient-auto",
        activityPrompt: prompt,
        turnMode: .patientAuto,
        manifestStore: store,
        interviewerRuntime: interviewer,
        recording: recorder,
        transcriber: transcriber,
        credentialReader: credentialStore,
        semanticEndpointClassifier: classifier
      )
      let run = try await executePatientAutoScenario(coordinator)

      let persisted = try await store.load(sessionID: sessionID)
      let classifierCalls = await classifier.invocationCount()
      let durableAtEntry = await classifier.authorizationWasDurableAtEntry()
      let transcriberCalls = await transcriber.invocationCount()
      let interviewerCalls = await interviewer.invocationCount()
      guard validatePendingSnapshot(run.pending),
            validateCompletedSnapshot(run.completed),
            validatePersistence(persisted, completed: run.completed),
            validateCallCounts(
              classifier: classifierCalls,
              durableAtEntry: durableAtEntry,
              recorderBegins: recorder.beginCount,
              recorderFinishes: recorder.finishCount,
              transcriber: transcriberCalls,
              interviewer: interviewerCalls
            ) else {
        if run.completed.endpointEvaluations.first?.failure?.reason == .missingCredential {
          fail(
            "Endpoint smoke failed: Interview Arc Live has no readable Groq credential.",
            code: 70
          )
        }
        fail("Endpoint smoke failed: functional Patient Auto invariants were not satisfied.", code: 70)
      }
      print("Installed Patient Auto Groq endpoint and automatic Hand off smoke passed.")
    } catch SegmentSpeechCoordinatorError.credentialUnavailable {
      fail(
        "Endpoint smoke failed: Interview Arc Live has no readable Groq credential.",
        code: 70
      )
    } catch {
      fail("Endpoint smoke failed before durable Patient Auto verification completed.", code: 70)
    }
  }

  @MainActor
  private static func executePatientAutoScenario(
    _ coordinator: SegmentSpeechCoordinator
  ) async throws -> (pending: InterviewRoomSnapshot, completed: InterviewRoomSnapshot) {
    _ = try await coordinator.giveCandidateFloor(
      commandID: CommandID("installed-patient-auto-floor")
    )
    _ = try await coordinator.beginSegment(
      commandID: CommandID("installed-patient-auto-begin")
    )
    let pending = try await coordinator.finishSegment(
      commandID: CommandID("installed-patient-auto-finish"),
      transcriptionCommandID: CommandID("installed-patient-auto-transcribe")
    )
    try await Task.sleep(
      for: .milliseconds(EndpointGrace.durationMilliseconds + 1_000)
    )
    return (pending, coordinator.snapshot)
  }

  private static func validatePendingSnapshot(
    _ pending: InterviewRoomSnapshot
  ) -> Bool {
    pending.turnMode == .patientAuto
      && pending.phase == .candidateFloor
      && pending.turns.isEmpty
      && pending.endpointGraces.count == 1
      && pending.endpointGraces.first?.lifecycle == .pending
  }

  private static func validateCompletedSnapshot(
    _ completed: InterviewRoomSnapshot
  ) -> Bool {
    completed.turnMode == .patientAuto
      && completed.phase == .interviewerTurn
      && completed.turns.count == 2
      && completed.segments.count == 1
      && completed.segments.first?.selectedCandidate?.body == transcript
      && completed.segments.first?.committedTurnID != nil
      && completed.endpointEvaluations.count == 1
      && completed.endpointEvaluations.first?.lifecycle == .proposalStored
      && completed.endpointEvaluations.first?.proposal?.decision == .likelyEnd
      && completed.endpointEvaluations.first?.failure == nil
      && completed.endpointGraces.count == 1
      && completed.endpointGraces.first?.lifecycle == .completed
      && completed.endpointGraces.first?.completedCandidateTurnID
        == completed.segments.first?.committedTurnID
  }

  private static func validatePersistence(
    _ persisted: SessionManifest?,
    completed: InterviewRoomSnapshot
  ) -> Bool {
    persisted?.endpointEvaluations == completed.endpointEvaluations
      && persisted?.endpointGraces == completed.endpointGraces
      && persisted?.phase == .interviewerTurn
      && persisted?.turns == completed.turns
  }

  private static func validateCallCounts(
    classifier: Int,
    durableAtEntry: Bool,
    recorderBegins: Int,
    recorderFinishes: Int,
    transcriber: Int,
    interviewer: Int
  ) -> Bool {
    classifier == 1
      && durableAtEntry
      && recorderBegins == 1
      && recorderFinishes == 1
      && transcriber == 1
      && interviewer == 1
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
        validating: "installed-patient-auto-segment.m4a"
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
      displayMarkdown: "What trade-off would you evaluate next?",
      spokenText: "What trade-off would you evaluate next?"
    )
  }

  func invocationCount() -> Int { calls }
}

private enum EndpointSmokeAssertionError: Error {
  case unexpectedClassifierEntry
}
