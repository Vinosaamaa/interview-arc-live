import Foundation
import XCTest
import InterviewArcLiveCore
import InterviewArcLiveSpeechOutputAdapter
@testable import InterviewArcLive
@testable import InterviewArcLiveHostedClient

@MainActor
final class SystemDesignAutomaticDeliveryTests: XCTestCase {
    func testAutomaticAnswerSpeaksAndSavesWebsitePairWithoutManualDeliveryCalls() async throws {
        let fixture = try await AutomaticDeliveryFixture()
        defer { fixture.removeTemporaryFiles() }
        await fixture.conversation.enableContinuousListening()
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("automatic-opening"))
        await fixture.speech.waitUntilIdle()
        XCTAssertEqual(fixture.player.beginCount, 1)
        XCTAssertEqual(fixture.model.snapshot?.phase, .candidateFloor)
        let startsBeforeSpeech = await fixture.transport.startTimerRequestCount
        XCTAssertEqual(startsBeforeSpeech, 0)

        fixture.segmenter.emit(.speechStarted)
        try await waitUntil {
            fixture.conversation.snapshot.segments.contains { $0.lifecycle == .recording }
        }
        fixture.segmenter.emit(.speechEnded)
        try await waitUntil {
            fixture.model.hostedSnapshot.activity?.pairs.count == 1
                && fixture.player.beginCount == 2
        }
        await fixture.speech.waitUntilIdle()
        XCTAssertEqual(fixture.model.snapshot?.turns.count, 3)
        XCTAssertEqual(fixture.model.snapshot?.phase, .candidateFloor)
        XCTAssertEqual(fixture.segmenter.mode, .candidateListening)
        XCTAssertEqual(fixture.model.snapshot?.interviewerUtterances.filter {
            $0.selectedAudio != nil
        }.count, 2)
        let pair = try XCTUnwrap(fixture.model.hostedSnapshot.activity?.pairs.first)
        XCTAssertEqual(pair.candidate.text, "The durable queue retries failed deliveries.")
        XCTAssertEqual(pair.interviewer.spokenText, "How do you prevent duplicate delivery?")
        let committed = await fixture.transport.pairRequestCount
        XCTAssertEqual(committed, 1)
        let timerStarts = await fixture.transport.startTimerRequestCount
        XCTAssertEqual(timerStarts, 1, "Automatic capture starts the hosted timer")
        XCTAssertTrue(fixture.model.hostedTimerIsRunning)

        // Replaying an already-applied command must neither speak nor upload again.
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("automatic-opening"))
        await fixture.speech.waitUntilIdle()
        XCTAssertEqual(fixture.player.beginCount, 2)
        let afterReplay = await fixture.transport.pairRequestCount
        XCTAssertEqual(afterReplay, 1)
    }

    func testResumedSpeechIsCapturedWhileThePriorSegmentIsStillTranscribing() async throws {
        let transcriber = AutomaticDeferredTranscriber()
        let fixture = try await AutomaticDeliveryFixture(transcriber: transcriber)
        defer {
            transcriber.releaseFirst()
            fixture.removeTemporaryFiles()
        }
        await fixture.conversation.enableContinuousListening()
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("overlap-opening"))
        await fixture.speech.waitUntilIdle()
        fixture.segmenter.emit(.speechStarted)
        try await waitUntil {
            fixture.conversation.snapshot.segments.contains { $0.lifecycle == .recording }
        }
        fixture.segmenter.emit(.speechEnded)
        try await waitUntil { transcriber.requests == 1 }
        fixture.segmenter.emit(.speechStarted)
        try await waitUntil {
            fixture.conversation.snapshot.segments.count == 2
                && fixture.conversation.snapshot.segments.last?.lifecycle == .recording
        }
        fixture.segmenter.emit(.speechEnded)
        try await waitUntil {
            fixture.conversation.snapshot.segments.last?.lifecycle == .audioReady
        }
        XCTAssertEqual(transcriber.requests, 1)
        transcriber.releaseFirst()
        try await waitUntil { fixture.model.hostedSnapshot.activity?.pairs.count == 1 }
        await fixture.speech.waitUntilIdle()
        let text = try XCTUnwrap(fixture.model.hostedSnapshot.activity?.pairs.first?.candidate.text)
        XCTAssertEqual(text, "First I use a durable queue.\n\nThen I add idempotent consumers.")
        XCTAssertEqual(transcriber.requests, 2)
        XCTAssertEqual(fixture.player.beginCount, 2)
    }

    func testQuitWaitsForPendingTranscriptionAndDoesNotGenerateAnotherReply() async throws {
        let transcriber = AutomaticDeferredTranscriber()
        let fixture = try await AutomaticDeliveryFixture(transcriber: transcriber)
        defer { transcriber.releaseFirst(); fixture.removeTemporaryFiles() }
        await fixture.conversation.enableContinuousListening()
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("quit-opening"))
        await fixture.speech.waitUntilIdle()
        fixture.segmenter.emit(.speechStarted)
        try await waitUntil {
            fixture.conversation.snapshot.segments.first?.lifecycle == .recording
        }
        fixture.segmenter.emit(.speechEnded)
        try await waitUntil { transcriber.requests == 1 }
        var quitFinished = false
        let quitting = Task { @MainActor in
            try await fixture.conversation.prepareForTermination(commandID: CommandID("quit-pending"))
            quitFinished = true
        }
        try await waitUntil { fixture.segmenter.mode == .disarmed }
        XCTAssertFalse(quitFinished)
        transcriber.releaseFirst()
        try await quitting.value
        XCTAssertTrue(quitFinished)
        XCTAssertEqual(fixture.conversation.snapshot.segments.first?.selectedCandidate?.body,
            "First I use a durable queue.")
        XCTAssertEqual(fixture.conversation.snapshot.turns.count, 1)
        XCTAssertEqual(fixture.player.beginCount, 1)
        XCTAssertEqual(fixture.segmenter.mode, .disarmed)
    }

    func testQuitJoinsAnAutomaticInterviewerResponseAndItsWebsiteSave() async throws {
        let runtime = AutomaticDeferredInterviewer()
        let fixture = try await AutomaticDeliveryFixture(runtime: runtime)
        defer { runtime.releaseReply(); fixture.removeTemporaryFiles() }
        await fixture.conversation.enableContinuousListening()
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("reply-quit-opening"))
        await fixture.speech.waitUntilIdle()
        fixture.segmenter.emit(.speechStarted)
        try await waitUntil { fixture.conversation.snapshot.segments.first?.lifecycle == .recording }
        fixture.segmenter.emit(.speechEnded)
        try await waitUntil { runtime.requests == 2 }
        var quitFinished = false
        let quitting = Task { @MainActor in
            try await fixture.conversation.prepareForTermination(commandID: CommandID("quit-reply"))
            quitFinished = true
        }
        try await waitUntil { fixture.segmenter.mode == .disarmed }
        XCTAssertFalse(quitFinished)
        runtime.releaseReply()
        try await quitting.value
        XCTAssertTrue(quitFinished)
        XCTAssertEqual(fixture.conversation.snapshot.turns.count, 3)
        XCTAssertEqual(fixture.model.hostedSnapshot.activity?.pairs.count, 1)
        XCTAssertEqual(fixture.segmenter.mode, .disarmed)
    }

    func testPausedMicrophoneCanResumeWithoutSwitchingTurnModes() async throws {
        let fixture = try await AutomaticDeliveryFixture()
        defer { fixture.removeTemporaryFiles() }
        await fixture.conversation.enableContinuousListening()
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("resume-opening"))
        await fixture.speech.waitUntilIdle()
        XCTAssertFalse(fixture.model.isMicrophonePaused)
        await fixture.model.toggleMicrophone()
        XCTAssertTrue(fixture.model.isMicrophonePaused)
        XCTAssertEqual(fixture.segmenter.mode, .disarmed)
        XCTAssertEqual(fixture.model.floorStatePresentation.full.label, "Microphone paused")
        await fixture.model.toggleMicrophone()
        XCTAssertFalse(fixture.model.isMicrophonePaused)
        XCTAssertEqual(fixture.segmenter.mode, .candidateListening)
        XCTAssertEqual(fixture.model.turnMode, .continuousConversation)
        XCTAssertEqual(fixture.model.floorStatePresentation.full.label, "Listening")
    }

    func testPauseDuringSpeechTranscribesSavedAudioAndResumeNeedsNoRecoveryClick() async throws {
        let fixture = try await AutomaticDeliveryFixture()
        defer { fixture.removeTemporaryFiles() }
        await fixture.conversation.enableContinuousListening()
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("active-pause-opening"))
        await fixture.speech.waitUntilIdle()
        fixture.segmenter.emit(.speechStarted)
        try await waitUntil { fixture.conversation.snapshot.segments.first?.lifecycle == .recording }
        await fixture.model.toggleMicrophone()
        try await waitUntil { fixture.conversation.snapshot.segments.first?.selectedCandidate != nil }
        XCTAssertTrue(fixture.model.isMicrophonePaused)
        XCTAssertEqual(fixture.model.hostedSnapshot.activity?.pairs.count, 0)
        await fixture.model.toggleMicrophone()
        try await waitUntil { fixture.model.hostedSnapshot.activity?.pairs.count == 1 }
        await fixture.speech.waitUntilIdle()
        XCTAssertFalse(fixture.model.isMicrophonePaused)
        XCTAssertEqual(fixture.segmenter.mode, .candidateListening)
    }

    func testAutomaticCaptureCannotRecordAfterHostedWriteAccessIsReleased() async throws {
        let fixture = try await AutomaticDeliveryFixture()
        defer { fixture.removeTemporaryFiles() }
        await fixture.conversation.enableContinuousListening()
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("read-only-opening"))
        await fixture.speech.waitUntilIdle()
        let released = await fixture.hosted.prepareForTermination()
        XCTAssertTrue(released)
        XCTAssertFalse(fixture.model.isHostedWritable)
        fixture.segmenter.emit(.speechStarted)
        try await waitUntil { fixture.model.errorMessage?.contains("Reconnect") == true }
        XCTAssertTrue(fixture.conversation.snapshot.segments.isEmpty)
        let timerStarts = await fixture.transport.startTimerRequestCount
        XCTAssertEqual(timerStarts, 0)
    }

    func testFailedAutomaticWebsiteSaveKeepsLocalEvidenceAndRecoversWithoutRespeaking() async throws {
        let fixture = try await AutomaticDeliveryFixture()
        defer { fixture.removeTemporaryFiles() }
        await fixture.transport.failNextPair()
        await fixture.conversation.enableContinuousListening()
        _ = try await fixture.conversation.requestOpeningInterviewerTurn(
            commandID: CommandID("recovery-opening"))
        await fixture.speech.waitUntilIdle()
        fixture.segmenter.emit(.speechStarted)
        try await waitUntil {
            fixture.conversation.snapshot.segments.contains { $0.lifecycle == .recording }
        }
        fixture.segmenter.emit(.speechEnded)
        try await waitUntil {
            fixture.model.snapshot?.turns.count == 3 && fixture.model.errorMessage != nil
        }
        await fixture.speech.waitUntilIdle()
        XCTAssertEqual(fixture.model.snapshot?.phase, .candidateFloor)
        XCTAssertEqual(fixture.player.beginCount, 2)
        XCTAssertEqual(fixture.model.snapshot?.interviewerUtterances.filter {
            $0.selectedAudio != nil
        }.count, 2)
        XCTAssertEqual(fixture.model.hostedSnapshot.activity?.pairs.count, 0)

        await fixture.hostedSession.recoverPendingOperations()
        _ = try await fixture.hostedSession.refresh()
        try await fixture.hosted.clearResult()
        let canQuit = await fixture.model.prepareHostedForTermination()
        XCTAssertTrue(canQuit)
        XCTAssertEqual(fixture.model.hostedSnapshot.activity?.pairs.count, 1)
        XCTAssertEqual(fixture.player.beginCount, 2)
        let requests = await fixture.transport.pairRequestCount
        XCTAssertEqual(requests, 2, "The failed upload is retried once through its durable outbox")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Automatic voice and website delivery did not complete")
        throw AutomaticDeliveryFailure.timeout
    }
}

private enum AutomaticDeliveryFailure: Error { case timeout, unexpectedRequest }

@MainActor
private final class AutomaticDeliveryFixture {
    let root: URL
    let preferences: UserDefaults
    let preferenceSuite: String
    let transport = AutomaticHostedTransport()
    let player = AutomaticSpeechPlayer()
    let segmenter = DeterministicAcousticSegmenter()
    let conversation: SegmentSpeechCoordinator
    let speech: InterviewerSpeechCoordinator
    let model: SystemDesignRoomModel
    let hostedSession: HostedPracticeSession
    let hosted: HostedPracticeController

    init(transcriber: any SegmentTranscribing = AutomaticTranscriber(),
         runtime: any InterviewerProvider = AutomaticInterviewer()) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-speech-smoke-automatic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        preferenceSuite = "live-tests-automatic-\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: preferenceSuite))
        let token = LiveIntegrationTokenStore()
        try await token.useUntilQuit("synthetic-test-token")
        hostedSession = HostedPracticeSession(
            client: LiveV1Client(tokenReader: token, transport: transport),
            tokenReader: token,
            identityStore: PrivateLiveIdentityStore(directoryURL: root.appendingPathComponent("identity")),
            outbox: PrivateLiveOutboxStore(directoryURL: root.appendingPathComponent("outbox")),
            clipStore: PrivateLiveClipStore(directoryURL: root.appendingPathComponent("clips")),
            clock: AutomaticClock(),
            holderSessionID: "automatic-test-holder"
        )
        hosted = HostedPracticeController(
            tokenStore: token,
            session: hostedSession,
            eventStream: try LiveEventStream(
                origin: URL(string: "https://example.invalid")!, tokenReader: token),
            tokenValidator: { _ in }
        )
        // Seed hosted authority through the real session and a synthetic transport.
        // Controller.open/refresh is deliberately not called: no WebSocket starts.
        _ = await hostedSession.open()
        try await hosted.clearResult()
        conversation = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("automatic-app-test"), activityID: "activity-1",
            activityPrompt: ActivityPrompt(specialty: .systemDesign, stage: "Design",
                question: "Design a notification service.", requestedParts: []),
            manifestStore: InMemorySessionManifestStore(), interviewerRuntime: runtime,
            recording: AutomaticRecording(), transcriber: transcriber,
            credentialReader: AutomaticCredential(), semanticEndpointClassifier: AutomaticEndpoint(),
            endpointGraceScheduler: AutomaticGrace(), acousticSegmenter: segmenter
        )
        speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation, provider: AutomaticSpeechProvider(), player: player,
            audioStore: LiveInterviewerSpeechAudioStore(validatingTemporarySmokeRoot: root)
        )
        model = SystemDesignRoomModel(
            interviewerRuntime: runtime, preferences: preferences,
            initialCoordinator: conversation, initialSpeechCoordinator: speech,
            hostedController: hosted
        )
    }

    func removeTemporaryFiles() {
        preferences.removePersistentDomain(forName: preferenceSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct AutomaticInterviewer: InterviewerProvider {
    let providerName = "Synthetic interviewer"
    func preflight() async -> InterviewerReadiness { .ready }
    func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse {
        .init(displayMarkdown: "How do you prevent duplicate delivery?",
              spokenText: "How do you prevent duplicate delivery?")
    }
}
private struct AutomaticCredential: GroqCredentialReading {
    func readGroqCredential() async throws -> String { "synthetic-key" }
}
private struct AutomaticEndpoint: SemanticEndpointClassifying {
    func classify(_ context: SemanticEndpointContext) async throws -> SemanticEndpointProposal {
        .init(decision: .likelyEnd, reasonCode: .answerResolvesQuestion)
    }
}
private struct AutomaticGrace: EndpointGraceScheduling {
    func waitForGrace() async throws {}
}
private struct AutomaticClock: LiveClock {
    func epochMilliseconds() -> LiveEpochMilliseconds { 1_000_000 }
}
private struct AutomaticTranscriber: SegmentTranscribing {
    func transcribe(_ request: SegmentTranscriptionRequest, credential: String) async throws
        -> SegmentTranscriptionResult {
        .init(body: "The durable queue retries failed deliveries.", quality: .verified)
    }
}
@MainActor
private final class AutomaticRecording: SegmentRecording {
    private var request: SegmentCaptureRequest?
    func setUnexpectedTerminationHandler(_ handler: (@MainActor @Sendable () -> Void)?) {}
    func beginCapture(_ request: SegmentCaptureRequest) async throws { self.request = request }
    func finishCapture() async throws -> CapturedAudioSegment {
        guard let request else { throw AutomaticDeliveryFailure.unexpectedRequest }
        self.request = nil
        return .init(audioIdentity: request.reservedAudioIdentity,
              startedAtMilliseconds: 1_000, endedAtMilliseconds: 2_000,
              durationMilliseconds: 1_000, decodedDurationMilliseconds: 1_000,
              byteCount: 4_096, isPlayable: true, isPartial: false,
              integrityReasons: [])
    }
    func recoverCapture(_ request: SegmentCaptureRequest) async throws -> CapturedAudioSegment? { nil }
    func playbackURL(sessionID: SessionID, audioIdentity: SegmentAudioIdentity) async throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(audioIdentity.fileName)
    }
}
@MainActor
private final class AutomaticSpeechPlayer: InterviewerSpeechPlaying {
    var beginCount = 0
    func beginStreaming(sampleRate: Int, channelCount: Int) { beginCount += 1 }
    func enqueue(_ chunk: InterviewerSpeechPCMChunk) {}
    func finishStreaming() {}
    func stop() {}
    func play(_ request: InterviewerSpeechPlaybackRequest) {}
}
private actor AutomaticSpeechProvider: InterviewerSpeechProvider {
    nonisolated let provenance = InterviewerSpeechProvenance(
        providerID: "synthetic-speech", modelID: "fixture/speech",
        modelRevision: String(repeating: "a", count: 40), profile: .maraV1)
    func readiness() -> InterviewerSpeechReadiness { .ready }
    func prepare(_ policy: InterviewerSpeechPreparationPolicy,
                 progress: @escaping @Sendable (InterviewerSpeechPreparationProgress) -> Void)
        -> InterviewerSpeechReadiness { .ready }
    func synthesize(_ request: InterviewerSpeechSynthesisRequest) async throws
        -> AsyncThrowingStream<InterviewerSpeechEvent, Error> {
        AsyncThrowingStream { stream in
            stream.yield(.pcm(.init(samples: Array(repeating: 0.1, count: 24_000),
                                    sampleRate: 24_000, channelCount: 1)))
            stream.yield(.completed(.init(chunkCount: 1, generatedSampleCount: 24_000,
                timeToFirstAudioMilliseconds: 1, totalGenerationMilliseconds: 1)))
            stream.finish()
        }
    }
    func unload() {}
    func cancelSynthesis() {}
    func removePreparedModel() -> InterviewerSpeechReadiness { .notInstalled }
}

private actor AutomaticHostedTransport: LiveV1Transport {
    private(set) var pairRequestCount = 0
    private(set) var startTimerRequestCount = 0
    private var timer: LiveTimer?
    private var pairs: [LivePair] = []
    private var lease: LiveLeaseGrant?
    private var failPair = false

    func failNextPair() { failPair = true }

    func send(_ request: LiveV1Request) async throws -> LiveV1HTTPResponse {
        if request.method == .get {
            if request.path == "/live/v1/today" { return try response(today) }
            if request.path == "/live/v1/activities/activity-1" { return try response(activity) }
            if request.path.contains("/receipts/") {
                return LiveV1HTTPResponse(statusCode: 404,
                    body: try JSONEncoder().encode(LiveErrorBody(
                        error: "Receipt not found", code: "receipt_not_found", retryable: false,
                        holderPresent: nil, expiresAt: nil)))
            }
            throw AutomaticDeliveryFailure.unexpectedRequest
        }
        let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
        let operation: String
        var granted: LiveLeaseGrant?
        if request.path.hasSuffix("/lease/acquire") {
            operation = "lease.acquire"
            granted = LiveLeaseGrant(fencingToken: 7, expiresAt: 1_090_000,
                holderSessionId: body["holderSessionId"] as? String ?? "")
            lease = granted
        } else if request.path.hasSuffix("/lease/release") {
            operation = "lease.release"
            lease = nil
        } else if request.path.hasSuffix("/commands") {
            operation = "command.\(body["command"] as? String ?? "")"
            if body["command"] as? String == "start" {
                startTimerRequestCount += 1
                timer = LiveTimer(accumulatedSeconds: 0, startedAt: 1_000_000,
                    runningSince: 1_000_000, completed: false, completedAt: nil, revision: 1)
            }
        } else if request.path.hasSuffix("/turn-pairs") {
            operation = "turn_pair.commit"
            pairRequestCount += 1
            if failPair {
                failPair = false
                throw LiveV1ClientError.transportUnavailable
            }
            let candidate = try JSONDecoder().decode(LiveCandidatePairInput.self,
                from: JSONSerialization.data(withJSONObject: body["candidate"]!))
            let interviewer = try JSONDecoder().decode(LiveInterviewerPairInput.self,
                from: JSONSerialization.data(withJSONObject: body["interviewer"]!))
            pairs.append(LivePair(pairId: body["pairId"] as! String,
                candidate: LiveCandidateTurn(turnId: candidate.turnId, text: candidate.text,
                    evidenceStatus: candidate.evidenceStatus, evidenceConfirmedAt: nil,
                    evidenceSatisfied: true, occurredAt: candidate.occurredAt, sequence: 1),
                interviewer: LiveInterviewerTurn(turnId: interviewer.turnId,
                    displayMarkdown: interviewer.displayMarkdown, spokenText: interviewer.spokenText,
                    occurredAt: interviewer.occurredAt, sequence: 2),
                clipId: nil, committedAt: 1_000_000))
        } else {
            throw AutomaticDeliveryFailure.unexpectedRequest
        }
        return try response(LiveMutationResponse(protocolVersion: 1, duplicate: false,
            receipt: LiveMutationReceipt(protocolVersion: 1,
                operationId: body["operationId"] as! String, activityId: "activity-1",
                operation: operation, committedAt: 1_000_000, result: [:]),
            activity: activity, lease: granted, selectedNextActivityId: nil,
            confirmation: nil, today: today, clip: nil))
    }

    private func response<T: Encodable>(_ value: T) throws -> LiveV1HTTPResponse {
        .init(statusCode: 200, body: try JSONEncoder().encode(value))
    }
    private var workbench: LiveWorkbench {
        .init(id: "workbench-1", revision: 1, openedPacificDate: "2026-09-07", openedAt: 900_000)
    }
    private var focus: LiveFocus {
        .init(activityId: "activity-1", sessionId: "session-1", focusedAt: 990_000)
    }
    private var summary: LiveActivitySummary {
        .init(id: "activity-1", questionId: "question-1", date: "2026-09-07",
              source: "fixture", type: .systemDesign, title: "Notifications",
              prompt: "Design a notification service.", allocatedSeconds: 2_700,
              sessionId: "session-1", lifecycle: .running, revision: 1, timer: timer,
              result: .init(value: nil, revision: 0))
    }
    private var today: LiveTodayProjection {
        .init(protocolVersion: 1, serverTime: 1_000_000, ownerRevision: 1,
              workbench: workbench, focus: focus, sessions: [], activities: [summary])
    }
    private var activity: LiveActivityProjection {
        .init(protocolVersion: 1, serverTime: 1_000_000, ownerRevision: 1,
              workbench: workbench, focus: focus, session: nil,
              activity: .init(id: summary.id, questionId: summary.questionId, date: summary.date,
                  source: summary.source, type: summary.type, title: summary.title,
                  prompt: summary.prompt, allocatedSeconds: summary.allocatedSeconds,
                  sessionId: summary.sessionId, lifecycle: summary.lifecycle,
                  revision: summary.revision, timer: timer, result: summary.result,
                  textEvidenceSatisfied: !pairs.isEmpty),
              lease: .init(active: lease != nil, holderPresent: lease != nil, expiresAt: lease?.expiresAt),
              pairs: pairs, clips: [])
    }
}

@MainActor
private final class AutomaticDeferredTranscriber: SegmentTranscribing {
    var requests = 0
    private var first: CheckedContinuation<Void, Never>?
    func transcribe(_ request: SegmentTranscriptionRequest, credential: String) async throws
        -> SegmentTranscriptionResult {
        requests += 1
        let index = requests
        if index == 1 { await withCheckedContinuation { first = $0 } }
        return .init(body: index == 1
            ? "First I use a durable queue."
            : "Then I add idempotent consumers.", quality: .verified)
    }
    func releaseFirst() {
        first?.resume()
        first = nil
    }
}

@MainActor
private final class AutomaticDeferredInterviewer: InterviewerProvider {
    nonisolated let providerName = "Synthetic deferred interviewer"
    var requests = 0
    private var reply: CheckedContinuation<Void, Never>?
    func preflight() async -> InterviewerReadiness { .ready }
    func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse {
        requests += 1
        if requests == 2 { await withCheckedContinuation { reply = $0 } }
        return .init(displayMarkdown: "How do you prevent duplicate delivery?",
            spokenText: "How do you prevent duplicate delivery?")
    }
    func releaseReply() { reply?.resume(); reply = nil }
}
