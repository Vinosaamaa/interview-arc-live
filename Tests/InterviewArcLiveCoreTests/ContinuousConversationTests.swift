import Foundation
import XCTest
@testable import InterviewArcLiveCore

@MainActor
final class ContinuousConversationTests: XCTestCase {
    func testNewSessionDefaultsToContinuousConversation() async throws {
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("cc-default"),
            activityID: "activity-cc-default",
            activityPrompt: try fixturePrompt(),
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: SilentInterviewerRuntime()
        )

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.turnMode, .continuousConversation)
        XCTAssertTrue(snapshot.floorHolds.isEmpty)
        XCTAssertFalse(snapshot.isFloorHeld)
    }

    func testRestorePreservesStoredManualModeAndEmptyFloorHolds() async throws {
        let store = InMemorySessionManifestStore()
        let sessionID = SessionID("cc-restore-manual")
        let created = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-cc-restore",
            activityPrompt: try fixturePrompt(),
            turnMode: .manual,
            manifestStore: store,
            interviewerRuntime: SilentInterviewerRuntime()
        )
        let createdMode = await created.snapshot().turnMode
        XCTAssertEqual(createdMode, .manual)

        let restored = try await InterviewRoomSession.restore(
            sessionID: sessionID,
            manifestStore: store,
            interviewerRuntime: SilentInterviewerRuntime()
        )
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.turnMode, .manual)
        XCTAssertTrue(snapshot.floorHolds.isEmpty)
    }

    func testLegacyManifestWithoutFloorHoldsDecodesAdditively() throws {
        let manifest = SessionManifest(
            sessionID: SessionID("cc-legacy"),
            activityID: "activity-cc-legacy",
            activityPrompt: try fixturePrompt(),
            phase: .candidateFloor,
            turnMode: .manual,
            turns: [],
            revision: 0,
            appliedCommands: []
        )
        let encoded = try JSONEncoder().encode(manifest)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "floorHolds")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: stripped)
        XCTAssertEqual(decoded.turnMode, .manual)
        XCTAssertTrue(decoded.floorHolds.isEmpty)
        XCTAssertNil(decoded.activeFloorHold)
    }

    func testHoldFloorPersistsBeforeCancellingGraceAndBlocksHandOff() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeFloorSession(
            store: store,
            turnMode: .continuousConversation
        )
        try await makeTranscribedSegment(session: session, stem: "held-answer")
        let evaluation = try await authorizeLikelyEnd(session: session, stem: "held")
        _ = try await session.execute(
            .activateEndpointGrace(
                commandID: CommandID("held-grace"),
                evaluationID: evaluation.id,
                expectedBoardAttachment: .noBoard
            )
        )
        let pendingLifecycle = await session.snapshot().endpointGraces.last?.lifecycle
        XCTAssertEqual(pendingLifecycle, .pending)

        let held = try await session.execute(
            .activateFloorHold(commandID: CommandID("hold-1"))
        )
        XCTAssertTrue(held.isFloorHeld)
        XCTAssertEqual(held.endpointGraces.last?.lifecycle, .cancelled)
        XCTAssertEqual(held.endpointGraces.last?.cancellationReason, .floorHold)

        do {
            _ = try await session.execute(
                .completeEndpointGrace(
                    commandID: CommandID("held-complete"),
                    graceID: try XCTUnwrap(held.endpointGraces.last?.id),
                    boardAttachment: .noBoard
                )
            )
            XCTFail("Grace must not complete while the floor is held")
        } catch let error as InterviewRoomSessionError {
            XCTAssertEqual(error, .endpointGraceNotFound(try XCTUnwrap(held.endpointGraces.last?.id)))
        }

        do {
            _ = try await session.execute(
                .handOffSegments(commandID: CommandID("held-handoff"))
            )
            XCTFail("Explicit Hand off must not run while held")
        } catch let error as InterviewRoomSessionError {
            XCTAssertEqual(error, .floorHoldActive)
        }
    }

    func testSendAnswerReleasesHoldAndHandsOffOnce() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = CountingInterviewerRuntime()
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("cc-send"),
            activityID: "activity-cc-send",
            activityPrompt: try fixturePrompt(),
            turnMode: .continuousConversation,
            manifestStore: store,
            interviewerRuntime: runtime
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("cc-send-floor"))
        )
        try await makeTranscribedSegment(session: session, stem: "send")
        _ = try await session.execute(
            .activateFloorHold(commandID: CommandID("send-hold"))
        )

        let sent = try await session.execute(
            .sendAnswer(
                commandID: CommandID("send-answer"),
                boardAttachment: .noBoard
            )
        )

        XCTAssertFalse(sent.isFloorHeld)
        XCTAssertEqual(sent.floorHolds.last?.lifecycle, .released)
        XCTAssertEqual(sent.floorHolds.last?.releaseReason, .sendAnswer)
        XCTAssertEqual(sent.phase, .interviewerTurn)
        let invocations = await runtime.invocationCount()
        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(sent.turns.count, 2)
    }

    func testAcousticEventsStartAndFinalizeASegmentWithoutRecordButtons() async throws {
        let segmenter = DeterministicAcousticSegmenter()
        let tracer = CapturingConversationBoundaryTracer()
        let recorder = CountingSegmentRecorder(
            capture: try capturedAudio(fileName: "vad-audio.m4a")
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("cc-vad"),
            activityID: "activity-cc-vad",
            activityPrompt: try fixturePrompt(),
            turnMode: .continuousConversation,
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: SilentInterviewerRuntime(),
            recording: recorder,
            transcriber: OneShotTranscriber(body: "A locally detected answer."),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: FixedEndpointClassifier(
                proposal: SemanticEndpointProposal(
                    decision: .likelyContinue,
                    reasonCode: .unfinishedThought
                )
            ),
            acousticSegmenter: segmenter,
            boundaryTracer: tracer
        )

        await coordinator.enableContinuousListening()
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("cc-vad-floor")
        )
        XCTAssertEqual(segmenter.mode, .candidateListening)
        XCTAssertGreaterThan(segmenter.armCount, 0)

        segmenter.emit(.speechStarted)
        try await waitUntil {
            coordinator.snapshot.segments.contains { $0.lifecycle == .recording }
        }
        XCTAssertEqual(recorder.beginCount, 1)

        segmenter.emit(.speechEnded)
        try await waitUntil {
            coordinator.snapshot.segments.contains {
                $0.selectedCandidate != nil && $0.committedTurnID == nil
            }
        }
        XCTAssertEqual(recorder.finishCount, 1)
        XCTAssertEqual(coordinator.snapshot.phase, .candidateFloor)
        XCTAssertTrue(coordinator.snapshot.turns.isEmpty)
        XCTAssertTrue(
            tracer.events.contains { $0.resultCode == "speech_started" }
        )
        XCTAssertTrue(
            tracer.events.contains { $0.resultCode == "speech_ended" }
        )
    }

    func testResumePendingWorkDoesNotAutoStartTheMicrophone() async throws {
        let store = InMemorySessionManifestStore()
        let sessionID = SessionID("cc-resume")
        let created = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-cc-resume",
            activityPrompt: try fixturePrompt(),
            turnMode: .continuousConversation,
            manifestStore: store,
            interviewerRuntime: SilentInterviewerRuntime()
        )
        _ = try await created.execute(
            .giveCandidateFloor(commandID: CommandID("cc-resume-floor"))
        )

        let recorder = CountingSegmentRecorder(
            capture: try capturedAudio(fileName: "resume-audio.m4a")
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: sessionID,
            activityID: "activity-cc-resume",
            activityPrompt: try fixturePrompt(),
            manifestStore: store,
            interviewerRuntime: SilentInterviewerRuntime(),
            recording: recorder,
            transcriber: OneShotTranscriber(body: "unused"),
            credentialReader: FixedCredentialReader(value: "credential")
        )
        _ = try await coordinator.resumePendingWork()
        XCTAssertEqual(recorder.beginCount, 0)
        XCTAssertEqual(coordinator.snapshot.turnMode, .continuousConversation)
        XCTAssertEqual(coordinator.snapshot.phase, .candidateFloor)
    }

    func testPlaybackStartArmsBargeInAndIgnoredNoiseDoesNotInterrupt() async throws {
        let fixture = try await makeBargeInFixture()
        await fixture.coordinator.enableContinuousListening()
        _ = try await fixture.coordinator.giveCandidateFloor(
            commandID: CommandID("cc-barge-noise-floor")
        )
        try await speakContinueSegment(
            coordinator: fixture.coordinator,
            segmenter: fixture.segmenter
        )
        _ = try await fixture.coordinator.handOff(
            commandID: CommandID("cc-barge-noise-handoff")
        )
        XCTAssertEqual(fixture.coordinator.snapshot.phase, .interviewerTurn)
        XCTAssertEqual(fixture.segmenter.mode, .disarmed)

        await fixture.coordinator.noteInterviewerPlaybackStarted()
        XCTAssertEqual(fixture.segmenter.mode, .bargeInDetection)

        fixture.segmenter.emit(.ignoredNoise)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.coordinator.snapshot.phase, .interviewerTurn)
        let ignoredNoiseStops = await fixture.stopper.stopCount
        XCTAssertEqual(ignoredNoiseStops, 0)
        XCTAssertEqual(fixture.recorder.beginCount, 1)
        XCTAssertTrue(
            fixture.tracer.events.contains { $0.resultCode == "ignored_noise" }
        )
        XCTAssertFalse(
            fixture.tracer.events.contains { $0.resultCode == "barge_in_confirmed" }
        )
    }

    func testConfirmedBargeInStopsPlaybackAndOpensCandidateFloor() async throws {
        let fixture = try await makeBargeInFixture()
        fixture.segmenter.preRoll = AcousticPreRoll(
            sampleRate: 16_000,
            channelCount: 1,
            samples: Array(repeating: 0.2, count: 6_400)
        )
        await fixture.coordinator.enableContinuousListening()
        _ = try await fixture.coordinator.giveCandidateFloor(
            commandID: CommandID("cc-barge-floor")
        )
        try await speakContinueSegment(
            coordinator: fixture.coordinator,
            segmenter: fixture.segmenter
        )
        _ = try await fixture.coordinator.handOff(
            commandID: CommandID("cc-barge-handoff")
        )
        await fixture.coordinator.noteInterviewerPlaybackStarted()

        fixture.segmenter.emit(.speechStarted)
        try await waitUntil {
            fixture.coordinator.snapshot.phase == .candidateFloor
                && fixture.recorder.beginCount == 2
        }
        let bargeInStops = await fixture.stopper.stopCount
        XCTAssertEqual(bargeInStops, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.phase, .candidateFloor)
        XCTAssertTrue(
            fixture.tracer.events.contains { $0.resultCode == "barge_in_confirmed" }
        )
        XCTAssertTrue(
            fixture.tracer.events.contains {
                $0.resultCode == "barge_in_confirmed" && $0.counts["pre_roll_ms"] == 400
            }
        )
    }

    func testPlaybackFinishReopensCandidateFloorAndRearmsListening() async throws {
        let fixture = try await makeBargeInFixture()
        await fixture.coordinator.enableContinuousListening()
        _ = try await fixture.coordinator.giveCandidateFloor(
            commandID: CommandID("cc-rearm-floor")
        )
        try await speakContinueSegment(
            coordinator: fixture.coordinator,
            segmenter: fixture.segmenter
        )
        _ = try await fixture.coordinator.handOff(
            commandID: CommandID("cc-rearm-handoff")
        )
        XCTAssertEqual(fixture.coordinator.snapshot.phase, .interviewerTurn)

        await fixture.coordinator.noteInterviewerPlaybackStarted()
        await fixture.coordinator.noteInterviewerPlaybackFinished()

        XCTAssertEqual(fixture.coordinator.snapshot.phase, .candidateFloor)
        XCTAssertEqual(fixture.segmenter.mode, .candidateListening)
        let finishedStops = await fixture.stopper.stopCount
        XCTAssertEqual(finishedStops, 0)
        XCTAssertEqual(fixture.recorder.beginCount, 1)
    }

    private func makeBargeInFixture() async throws -> BargeInFixture {
        let segmenter = DeterministicAcousticSegmenter()
        let tracer = CapturingConversationBoundaryTracer()
        let recorder = CountingSegmentRecorder(
            capture: try capturedAudio(fileName: "barge-in-audio.m4a")
        )
        let stopper = CountingPlaybackStopper()
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("cc-barge-\(UUID().uuidString)"),
            activityID: "activity-cc-barge",
            activityPrompt: try fixturePrompt(),
            turnMode: .continuousConversation,
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: SilentInterviewerRuntime(),
            recording: recorder,
            transcriber: OneShotTranscriber(body: "A locally detected answer."),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: FixedEndpointClassifier(
                proposal: SemanticEndpointProposal(
                    decision: .likelyContinue,
                    reasonCode: .unfinishedThought
                )
            ),
            acousticSegmenter: segmenter,
            boundaryTracer: tracer
        )
        coordinator.setInterviewerPlaybackStopper { commandID, reason in
            XCTAssertEqual(reason, .bargeIn)
            await stopper.stop(commandID: commandID)
        }
        return BargeInFixture(
            coordinator: coordinator,
            segmenter: segmenter,
            recorder: recorder,
            stopper: stopper,
            tracer: tracer
        )
    }

    private func speakContinueSegment(
        coordinator: SegmentSpeechCoordinator,
        segmenter: DeterministicAcousticSegmenter
    ) async throws {
        segmenter.emit(.speechStarted)
        try await waitUntil {
            coordinator.snapshot.segments.contains { $0.lifecycle == .recording }
        }
        segmenter.emit(.speechEnded)
        try await waitUntil {
            coordinator.snapshot.segments.contains {
                $0.selectedCandidate != nil && $0.committedTurnID == nil
            }
        }
    }

    private func makeFloorSession(
        store: InMemorySessionManifestStore,
        turnMode: TurnMode
    ) async throws -> InterviewRoomSession {
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("cc-session-\(UUID().uuidString)"),
            activityID: "activity-cc-session",
            activityPrompt: try fixturePrompt(),
            turnMode: turnMode,
            manifestStore: store,
            interviewerRuntime: SilentInterviewerRuntime()
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("cc-floor"))
        )
        return session
    }

    private func makeTranscribedSegment(
        session: InterviewRoomSession,
        stem: String
    ) async throws {
        let began = try await session.execute(
            .beginSegment(commandID: CommandID("\(stem)-begin"))
        )
        let segmentID = try XCTUnwrap(began.segments.last?.id)
        _ = try await session.execute(
            .recordSegmentCaptureOutcome(
                commandID: CommandID("\(stem)-started"),
                segmentID: segmentID,
                outcome: .recordingStarted
            )
        )
        _ = try await session.execute(
            .finalizeSegment(
                commandID: CommandID("\(stem)-finalize"),
                segmentID: segmentID
            )
        )
        _ = try await session.execute(
            .recordSegmentCaptureOutcome(
                commandID: CommandID("\(stem)-audio"),
                segmentID: segmentID,
                outcome: .finalized(try capturedAudio(fileName: "\(stem).m4a"))
            )
        )
        let authorized = try await session.execute(
            .authorizeSegmentTranscription(
                commandID: CommandID("\(stem)-auth"),
                segmentID: segmentID,
                kind: .initial,
                credentialFingerprint: InterviewRoomSession.credentialFingerprint("credential")
            )
        )
        let attempt = try XCTUnwrap(
            authorized.segments.first { $0.id == segmentID }?.transcriptionAttempts.last
        )
        _ = try await session.execute(
            .recordSegmentTranscriptionOutcome(
                commandID: CommandID("\(stem)-outcome"),
                segmentID: segmentID,
                attemptID: attempt.id,
                outcome: .candidate(
                    SegmentTranscriptionResult(
                        body: "A complete spoken answer.",
                        quality: .verified
                    )
                )
            )
        )
    }

    private func authorizeLikelyEnd(
        session: InterviewRoomSession,
        stem: String
    ) async throws -> EndpointEvaluation {
        let snapshot = await session.snapshot()
        let segment = try XCTUnwrap(snapshot.segments.last)
        let candidateID = try XCTUnwrap(segment.selectedCandidateID)
        let fingerprint = try InterviewRoomSession.endpointContextFingerprint(
            SemanticEndpointContext(
                interviewerQuestion: snapshot.activityPrompt.question,
                requestedParts: snapshot.activityPrompt.requestedParts,
                accumulatedAnswer: "A complete spoken answer.",
                latestSegment: "A complete spoken answer.",
                silenceDurationMilliseconds: 0,
                specialty: snapshot.activityPrompt.specialty.rawValue,
                stage: snapshot.activityPrompt.stage,
                explicitCue: false,
                workspaceActivity: []
            ),
            triggerSegmentID: segment.id,
            selectedCandidateIDs: [candidateID],
            questionTurnID: nil
        )
        let authorized = try await session.execute(
            .authorizeEndpointEvaluation(
                commandID: CommandID("\(stem)-eval"),
                triggerSegmentID: segment.id,
                selectedCandidateIDs: [candidateID],
                questionTurnID: nil,
                contextFingerprint: fingerprint
            )
        )
        let evaluation = try XCTUnwrap(authorized.endpointEvaluations.last)
        _ = try await session.execute(
            .recordEndpointEvaluationOutcome(
                commandID: CommandID("\(stem)-eval-outcome"),
                evaluationID: evaluation.id,
                outcome: .proposal(
                    SemanticEndpointProposal(
                        decision: .likelyEnd,
                        reasonCode: .answerResolvesQuestion
                    )
                )
            )
        )
        return evaluation
    }

    private func capturedAudio(fileName: String) throws -> CapturedAudioSegment {
        CapturedAudioSegment(
            audioIdentity: try SegmentAudioIdentity(validating: fileName),
            startedAtMilliseconds: 1_000,
            endedAtMilliseconds: 2_000,
            durationMilliseconds: 1_000,
            decodedDurationMilliseconds: 1_000,
            byteCount: 4_096,
            isPlayable: true,
            isPartial: false,
            integrityReasons: []
        )
    }

    private func fixturePrompt() throws -> ActivityPrompt {
        try ActivityPrompt(
            specialty: .systemDesign,
            stage: "High-level design",
            question: "Design a global notification system.",
            requestedParts: ["Explain delivery reliability and tradeoffs."]
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private struct BargeInFixture {
    let coordinator: SegmentSpeechCoordinator
    let segmenter: DeterministicAcousticSegmenter
    let recorder: CountingSegmentRecorder
    let stopper: CountingPlaybackStopper
    let tracer: CapturingConversationBoundaryTracer
}

private actor CountingPlaybackStopper {
    private(set) var stopCount = 0

    func stop(commandID _: CommandID) {
        stopCount += 1
    }
}

private actor SilentInterviewerRuntime: InterviewerRuntime {
    func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse {
        CanonicalInterviewerResponse(
            displayMarkdown: "What trade-off comes next?",
            spokenText: "What trade-off comes next?"
        )
    }
}

private actor CountingInterviewerRuntime: InterviewerRuntime {
    private var calls = 0

    func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse {
        calls += 1
        return CanonicalInterviewerResponse(
            displayMarkdown: "What trade-off comes next?",
            spokenText: "What trade-off comes next?"
        )
    }

    func invocationCount() -> Int { calls }
}

private final class CountingSegmentRecorder: SegmentRecording {
    private let capture: CapturedAudioSegment
    private(set) var beginCount = 0
    private(set) var finishCount = 0

    init(capture: CapturedAudioSegment) {
        self.capture = capture
    }

    func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {}

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
        URL(fileURLWithPath: "/private/tmp/\(audioIdentity.fileName)")
    }
}

private actor OneShotTranscriber: SegmentTranscribing {
    let body: String

    init(body: String) {
        self.body = body
    }

    func transcribe(
        _ request: SegmentTranscriptionRequest,
        credential: String
    ) async throws -> SegmentTranscriptionResult {
        SegmentTranscriptionResult(body: body, quality: .verified)
    }
}

private struct FixedCredentialReader: GroqCredentialReading {
    let value: String

    func readGroqCredential() async throws -> String { value }
}

private actor FixedEndpointClassifier: SemanticEndpointClassifying {
    let proposal: SemanticEndpointProposal

    init(proposal: SemanticEndpointProposal) {
        self.proposal = proposal
    }

    func classify(
        _ context: SemanticEndpointContext
    ) async throws -> SemanticEndpointProposal {
        proposal
    }
}
