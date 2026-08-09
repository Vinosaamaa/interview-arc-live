import Foundation
import XCTest
@testable import InterviewArcLiveCore

@MainActor
final class SegmentLifecycleTests: XCTestCase {
    func testTwoOrderedSegmentsBecomeOneCanonicalCandidateTurn() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(store: store)

        let first = try await makeTranscribedSegment(
            session: session,
            commandStem: "first",
            body: "  first spoken part  ",
            quality: .verified
        )
        let second = try await makeTranscribedSegment(
            session: session,
            commandStem: "second",
            body: "\nsecond spoken part\n",
            quality: .possibleContamination
        )

        let completed = try await session.execute(
            .handOffSegments(commandID: CommandID("handoff-segments"))
        )

        XCTAssertEqual(completed.segments.map(\.id), [first, second])
        XCTAssertEqual(completed.segments.map(\.ordinal), [0, 1])
        XCTAssertTrue(completed.segments.allSatisfy { $0.committedTurnID != nil })
        guard case .candidate(let candidate) = completed.turns.first else {
            return XCTFail("Expected one assembled Candidate Turn")
        }
        XCTAssertEqual(candidate.segmentIDs, [first, second])
        XCTAssertEqual(candidate.transcript.body, "first spoken part\n\nsecond spoken part")
        XCTAssertEqual(candidate.transcript.quality, .possibleContamination)

        let restored = try await InterviewRoomSession.restore(
            sessionID: completed.sessionID,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime()
        )
        let restoredSnapshot = await restored.snapshot()
        XCTAssertEqual(restoredSnapshot, completed)
    }

    func testBeginAndAttemptAuthorizationReceiptsAreIdempotent() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(store: store)
        let begin = InterviewRoomCommand.beginSegment(commandID: CommandID("stable-begin"))

        let accepted = try await session.apply(begin)
        let duplicate = try await session.apply(begin)
        XCTAssertEqual(accepted.disposition, .accepted)
        XCTAssertEqual(duplicate.disposition, .alreadyApplied)
        XCTAssertEqual(duplicate.snapshot.segments.count, 1)

        let segmentID = try XCTUnwrap(duplicate.snapshot.segments.first?.id)
        try await makeAudioReady(
            session: session,
            segmentID: segmentID,
            commandStem: "stable"
        )
        let authorization = InterviewRoomCommand.authorizeSegmentTranscription(
            commandID: CommandID("stable-attempt"),
            segmentID: segmentID,
            kind: .initial,
            credentialFingerprint: credentialFingerprint("credential-a")
        )
        let firstAttempt = try await session.apply(authorization)
        let duplicateAttempt = try await session.apply(authorization)
        XCTAssertEqual(firstAttempt.disposition, .accepted)
        XCTAssertEqual(duplicateAttempt.disposition, .alreadyApplied)
        XCTAssertEqual(
            duplicateAttempt.snapshot.segments[0].transcriptionAttempts.count,
            1
        )
    }

    func testSelectionPrefersQualityThenWordsAndRetainsEveryCandidate() async throws {
        let session = try await makeCandidateFloorSession(
            store: InMemorySessionManifestStore()
        )
        let begin = try await session.execute(
            .beginSegment(commandID: CommandID("select-begin"))
        )
        let segmentID = try XCTUnwrap(begin.segments.first?.id)
        try await makeAudioReady(session: session, segmentID: segmentID, commandStem: "select")

        try await recordCandidate(
            session: session,
            segmentID: segmentID,
            commandStem: "attempt-one",
            kind: .initial,
            body: "many contaminated transcript words survive here",
            quality: .possibleContamination,
            credential: "credential-a"
        )
        try await recordCandidate(
            session: session,
            segmentID: segmentID,
            commandStem: "attempt-two",
            kind: .retry,
            body: "verified short",
            quality: .verified,
            credential: "credential-a"
        )
        try await recordCandidate(
            session: session,
            segmentID: segmentID,
            commandStem: "attempt-three",
            kind: .retry,
            body: "verified answer with more words",
            quality: .verified,
            credential: "credential-a"
        )

        let selectedSnapshot = await session.snapshot()
        let segment = try XCTUnwrap(selectedSnapshot.segments.first)
        XCTAssertEqual(segment.transcriptCandidates.count, 3)
        XCTAssertEqual(segment.selectedCandidate?.body, "verified answer with more words")
        XCTAssertEqual(segment.selectedCandidate?.quality, .verified)
    }

    func testRejectedCredentialRequiresChangedFingerprint() async throws {
        let session = try await makeCandidateFloorSession(
            store: InMemorySessionManifestStore()
        )
        let begin = try await session.execute(
            .beginSegment(commandID: CommandID("credential-begin"))
        )
        let segmentID = try XCTUnwrap(begin.segments.first?.id)
        try await makeAudioReady(
            session: session,
            segmentID: segmentID,
            commandStem: "credential"
        )
        let rejectedFingerprint = credentialFingerprint("rejected-key")
        let authorized = try await session.execute(
            .authorizeSegmentTranscription(
                commandID: CommandID("credential-attempt"),
                segmentID: segmentID,
                kind: .initial,
                credentialFingerprint: rejectedFingerprint
            )
        )
        let attempt = try XCTUnwrap(authorized.segments[0].transcriptionAttempts.first)
        _ = try await session.execute(
            .recordSegmentTranscriptionOutcome(
                commandID: CommandID("credential-outcome"),
                segmentID: segmentID,
                attemptID: attempt.id,
                outcome: .failed(
                    SegmentTranscriptionFailure(
                        reason: .credentialRejected,
                        providerCode: .unauthorized,
                        credentialFingerprint: rejectedFingerprint
                    )
                )
            )
        )

        do {
            _ = try await session.execute(
                .authorizeSegmentTranscription(
                    commandID: CommandID("same-credential-retry"),
                    segmentID: segmentID,
                    kind: .retry,
                    credentialFingerprint: rejectedFingerprint
                )
            )
            XCTFail("Expected unchanged rejected credential to be blocked")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .rejectedCredentialUnchanged
            )
        }

        let changed = try await session.execute(
            .authorizeSegmentTranscription(
                commandID: CommandID("changed-credential-retry"),
                segmentID: segmentID,
                kind: .retry,
                credentialFingerprint: credentialFingerprint("replacement-key")
            )
        )
        XCTAssertEqual(changed.segments[0].transcriptionAttempts.count, 2)
        XCTAssertFalse(
            changed.segments[0].transcriptionAttempts[1].credentialFingerprint
                .contains("replacement-key")
        )
    }

    func testInsufficientSignalNeverAuthorizesProviderAttempt() async throws {
        let session = try await makeCandidateFloorSession(
            store: InMemorySessionManifestStore()
        )
        let begin = try await session.execute(
            .beginSegment(commandID: CommandID("silent-begin"))
        )
        let segmentID = try XCTUnwrap(begin.segments.first?.id)
        _ = try await session.execute(
            .recordSegmentCaptureOutcome(
                commandID: CommandID("silent-started"),
                segmentID: segmentID,
                outcome: .recordingStarted
            )
        )
        _ = try await session.execute(
            .finalizeSegment(commandID: CommandID("silent-finalize"), segmentID: segmentID)
        )
        _ = try await session.execute(
            .recordSegmentCaptureOutcome(
                commandID: CommandID("silent-audio"),
                segmentID: segmentID,
                outcome: .finalized(
                    try capturedAudio(
                        fileName: "silent.m4a",
                        integrityReasons: [.insufficientSignal]
                    )
                )
            )
        )

        do {
            _ = try await session.execute(
                .authorizeSegmentTranscription(
                    commandID: CommandID("silent-attempt"),
                    segmentID: segmentID,
                    kind: .initial,
                    credentialFingerprint: credentialFingerprint("credential")
                )
            )
            XCTFail("Expected insufficient-signal audio to stay away from Groq")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .segmentHasInsufficientSignal(segmentID)
            )
        }
        let unchanged = await session.snapshot()
        XCTAssertTrue(unchanged.segments[0].transcriptionAttempts.isEmpty)
    }

    func testUnresolvedSegmentBlocksHandOffAndExplicitExclusionClosesDraft() async throws {
        let session = try await makeCandidateFloorSession(
            store: InMemorySessionManifestStore()
        )
        let excludedID = try await makeTranscribedSegment(
            session: session,
            commandStem: "excluded",
            body: "do not include this",
            quality: .verified
        )
        let includedID = try await makeTranscribedSegment(
            session: session,
            commandStem: "included",
            body: "include this",
            quality: .verified
        )
        let unresolvedSnapshot = try await session.execute(
            .beginSegment(commandID: CommandID("unresolved-begin"))
        )
        let unresolvedID = try XCTUnwrap(unresolvedSnapshot.segments.last?.id)
        try await makeAudioReady(
            session: session,
            segmentID: unresolvedID,
            commandStem: "unresolved"
        )

        do {
            _ = try await session.execute(
                .handOffSegments(commandID: CommandID("blocked-handoff"))
            )
            XCTFail("Expected playable unresolved speech to block Hand off")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .unresolvedSegmentsPreventHandOff([unresolvedID])
            )
        }
        _ = try await session.execute(
            .excludeSegment(
                commandID: CommandID("exclude-explicitly"),
                segmentID: excludedID,
                reason: .userSkipped
            )
        )
        _ = try await session.execute(
            .excludeSegment(
                commandID: CommandID("exclude-unresolved"),
                segmentID: unresolvedID,
                reason: .noUsableTranscript
            )
        )

        let completed = try await session.execute(
            .handOffSegments(commandID: CommandID("handoff-with-exclusion"))
        )
        guard case .candidate(let candidate) = completed.turns.first else {
            return XCTFail("Expected Candidate Turn")
        }
        XCTAssertEqual(candidate.transcript.body, "include this")
        XCTAssertEqual(candidate.segmentIDs, [excludedID, includedID, unresolvedID])
        XCTAssertTrue(completed.segments.allSatisfy { $0.committedTurnID == candidate.id })

        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("new-floor"))
        )
        let next = try await session.execute(
            .beginSegment(commandID: CommandID("new-segment"))
        )
        XCTAssertEqual(next.segments.filter { $0.committedTurnID == nil }.count, 1)
    }

    func testAudioIdentityRejectsAbsoluteAndTraversalPathsDuringConstructionAndRestore() throws {
        XCTAssertThrowsError(try SegmentAudioIdentity(validating: "../escape.m4a"))
        XCTAssertThrowsError(try SegmentAudioIdentity(validating: "/tmp/escape.m4a"))
        XCTAssertThrowsError(try SegmentAudioIdentity(validating: "nested/escape.m4a"))
        XCTAssertNoThrow(try SegmentAudioIdentity(validating: "segment-safe_01.m4a"))

        let malicious = Data("\"../escape.m4a\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SegmentAudioIdentity.self, from: malicious))
    }

    func testRestoreRejectsCandidateTurnWithMissingSegmentMembership() async throws {
        let sessionID = SessionID("invalid-membership-session")
        let candidate = CandidateTurn(
            id: TurnID("candidate-turn"),
            commandID: CommandID("handoff"),
            transcript: CandidateTranscript(body: "answer", quality: .verified),
            segmentIDs: [SegmentID("missing-segment")]
        )
        let manifest = SessionManifest(
            sessionID: sessionID,
            activityID: "invalid-membership-activity",
            activityPrompt: try fixtureActivityPrompt(),
            phase: .interviewerProcessing,
            turnMode: .manual,
            turns: [.candidate(candidate)],
            segments: [],
            revision: 1,
            appliedCommands: []
        )
        let store = InMemorySessionManifestStore(manifests: [manifest])

        do {
            _ = try await InterviewRoomSession.restore(
                sessionID: sessionID,
                manifestStore: store,
                interviewerRuntime: fixtureRuntime()
            )
            XCTFail("Expected reverse Segment membership validation to fail")
        } catch let error as InterviewRoomSessionError {
            guard case .invalidManifest = error else {
                return XCTFail("Expected invalidManifest, received \(error)")
            }
        }
    }

    func testCoordinatorDoesNotReplayProviderForDuplicateFailedRetry() async throws {
        let recorder = StubSegmentRecorder(capture: try capturedAudio(fileName: "coordinator.m4a"))
        let transcriber = SequencedSegmentTranscriber(
            results: [
                .failure(.init(reason: .providerUnavailable, providerCode: .unavailable)),
                .failure(.init(reason: .providerUnavailable, providerCode: .unavailable)),
                .success(.init(body: "recovered transcript", quality: .verified)),
            ]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("coordinator-idempotency"),
            activityID: "activity-coordinator-idempotency",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: fixtureRuntime(),
            recording: recorder,
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential")
        )
        _ = try await coordinator.giveCandidateFloor(commandID: CommandID("floor"))
        _ = try await coordinator.beginSegment(commandID: CommandID("begin"))
        do {
            _ = try await coordinator.finishSegment(
                commandID: CommandID("finish"),
                transcriptionCommandID: CommandID("initial-attempt")
            )
            XCTFail("Expected initial provider failure")
        } catch {
            XCTAssertEqual(
                error as? SegmentSpeechCoordinatorError,
                .transcriptionFailed(.providerUnavailable)
            )
        }
        let segmentID = try XCTUnwrap(coordinator.snapshot.segments.first?.id)

        let retryID = CommandID("retry-once")
        do {
            _ = try await coordinator.retryTranscription(
                segmentID: segmentID,
                commandID: retryID
            )
            XCTFail("Expected retry provider failure")
        } catch {
            XCTAssertEqual(
                error as? SegmentSpeechCoordinatorError,
                .transcriptionFailed(.providerUnavailable)
            )
        }
        _ = try await coordinator.retryTranscription(segmentID: segmentID, commandID: retryID)
        let callsAfterDuplicate = await transcriber.invocationCount()
        XCTAssertEqual(callsAfterDuplicate, 2)

        let recovered = try await coordinator.retryTranscription(
            segmentID: segmentID,
            commandID: CommandID("retry-with-fresh-id")
        )
        let callsAfterRecovery = await transcriber.invocationCount()
        XCTAssertEqual(callsAfterRecovery, 3)
        XCTAssertEqual(recovered.segments[0].selectedCandidate?.body, "recovered transcript")
    }

    func testResumePendingWorkRecoversPartialWithoutProviderReplay() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(store: store)
        let begin = try await session.execute(
            .beginSegment(commandID: CommandID("interrupted-begin"))
        )
        let segmentID = try XCTUnwrap(begin.segments.first?.id)
        _ = try await session.execute(
            .recordSegmentCaptureOutcome(
                commandID: CommandID("interrupted-recording"),
                segmentID: segmentID,
                outcome: .recordingStarted
            )
        )

        let recoveredAudio = try capturedAudio(fileName: "recovered-partial.m4a", isPartial: true)
        let recorder = StubSegmentRecorder(capture: recoveredAudio, recovery: recoveredAudio)
        let transcriber = SequencedSegmentTranscriber(results: [])
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: begin.sessionID,
            activityID: begin.activityID,
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: recorder,
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential")
        )

        let recovered = try await coordinator.resumePendingWork()
        XCTAssertEqual(recovered.segments[0].lifecycle, .audioReady)
        XCTAssertEqual(recovered.segments[0].capturedAudio, recoveredAudio)
        let recoveryCount = recorder.recoveryCount()
        let providerCalls = await transcriber.invocationCount()
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(providerCalls, 0)
    }

    func testResumePendingWorkMarksAuthorizedAttemptInterruptedBeforeExplicitRetry() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(store: store)
        let segmentID = try await makeAudioReadySegment(
            session: session,
            commandStem: "interrupted-provider"
        )
        let fingerprint = credentialFingerprint("credential")
        _ = try await session.execute(
            .authorizeSegmentTranscription(
                commandID: CommandID("interrupted-provider-authorization"),
                segmentID: segmentID,
                kind: .initial,
                credentialFingerprint: fingerprint
            )
        )

        let transcriber = SequencedSegmentTranscriber(
            results: [
                .success(
                    SegmentTranscriptionResult(
                        body: "explicitly recovered transcript",
                        quality: .verified
                    )
                )
            ]
        )
        let interruptedSnapshot = await session.snapshot()
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: interruptedSnapshot.sessionID,
            activityID: "activity-segment-fixture",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "unused-interrupted.m4a")
            ),
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential")
        )

        let reconciled = try await coordinator.resumePendingWork()
        XCTAssertEqual(reconciled.segments[0].lifecycle, .audioReady)
        XCTAssertEqual(reconciled.segments[0].transcriptionAttempts.count, 1)
        XCTAssertEqual(reconciled.segments[0].transcriptionAttempts[0].state, .failed)
        XCTAssertEqual(
            reconciled.segments[0].transcriptionAttempts[0].failure?.reason,
            .interrupted
        )
        let callsBeforeExplicitRetry = await transcriber.invocationCount()
        XCTAssertEqual(callsBeforeExplicitRetry, 0)

        let completed = try await coordinator.transcribeSegment(
            segmentID: segmentID,
            commandID: CommandID("explicit-provider-retry")
        )
        XCTAssertEqual(completed.segments[0].transcriptionAttempts.count, 2)
        XCTAssertEqual(completed.segments[0].transcriptionAttempts[1].kind, .retry)
        XCTAssertEqual(
            completed.segments[0].selectedCandidate?.body,
            "explicitly recovered transcript"
        )
        let callsAfterExplicitRetry = await transcriber.invocationCount()
        XCTAssertEqual(callsAfterExplicitRetry, 1)
    }

    func testRecoveredZeroAttemptSegmentUsesInitialExplicitTranscription() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(store: store)
        let begin = try await session.execute(
            .beginSegment(commandID: CommandID("zero-attempt-begin"))
        )
        let segmentID = try XCTUnwrap(begin.segments.first?.id)
        _ = try await session.execute(
            .recordSegmentCaptureOutcome(
                commandID: CommandID("zero-attempt-recording"),
                segmentID: segmentID,
                outcome: .recordingStarted
            )
        )

        let recoveredAudio = try capturedAudio(fileName: "zero-attempt-recovered.m4a", isPartial: true)
        let recorder = StubSegmentRecorder(capture: recoveredAudio, recovery: recoveredAudio)
        let transcriber = SequencedSegmentTranscriber(
            results: [
                .success(
                    SegmentTranscriptionResult(body: "recovered first attempt", quality: .bestAvailable)
                )
            ]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: begin.sessionID,
            activityID: begin.activityID,
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: recorder,
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential")
        )
        _ = try await coordinator.resumePendingWork()

        let completed = try await coordinator.transcribeSegment(
            segmentID: segmentID,
            commandID: CommandID("zero-attempt-transcribe")
        )
        XCTAssertEqual(completed.segments[0].transcriptionAttempts.count, 1)
        XCTAssertEqual(completed.segments[0].transcriptionAttempts[0].kind, .initial)
        XCTAssertEqual(completed.segments[0].selectedCandidate?.body, "recovered first attempt")
        let explicitInvocationCount = await transcriber.invocationCount()
        XCTAssertEqual(explicitInvocationCount, 1)
    }

    func testUnexpectedTerminationPublishesPreservedAudioWithoutProviderInvocation() async throws {
        let recorder = StubSegmentRecorder(
            capture: try capturedAudio(fileName: "unexpected-partial.m4a", isPartial: true)
        )
        let transcriber = SequencedSegmentTranscriber(
            results: [
                .success(
                    SegmentTranscriptionResult(
                        body: "preserved partial answer",
                        quality: .bestAvailable
                    )
                )
            ]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("unexpected-observer-session"),
            activityID: "unexpected-observer-activity",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: fixtureRuntime(),
            recording: recorder,
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential")
        )
        _ = try await coordinator.giveCandidateFloor(commandID: CommandID("observer-floor"))
        _ = try await coordinator.beginSegment(commandID: CommandID("observer-begin"))

        let completed = expectation(description: "unexpected termination published preserved audio")
        let observer = SnapshotObserver(completed: completed)
        coordinator.setSnapshotHandler { snapshot in
            observer.receive(snapshot)
        }

        recorder.triggerUnexpectedTermination()
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(coordinator.snapshot.segments.first?.lifecycle, .audioReady)
        XCTAssertNil(coordinator.snapshot.segments.first?.selectedCandidate)
        let invocationCount = await transcriber.invocationCount()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(
            observer.lifecycles,
            [.recording, .finalizationAuthorized, .audioReady]
        )
    }

    func testRecorderStopFailureKeepsAuthorizationAndFreshStopRetries() async throws {
        let recorder = StubSegmentRecorder(
            capture: try capturedAudio(fileName: "stop-retry.m4a"),
            finishFailuresRemaining: 1
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("stop-retry-session"),
            activityID: "stop-retry-activity",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: fixtureRuntime(),
            recording: recorder,
            transcriber: SequencedSegmentTranscriber(results: []),
            credentialReader: FixedCredentialReader(value: "credential")
        )
        _ = try await coordinator.giveCandidateFloor(commandID: CommandID("stop-retry-floor"))
        _ = try await coordinator.beginSegment(commandID: CommandID("stop-retry-begin"))

        do {
            _ = try await coordinator.finalizeSegment(commandID: CommandID("stop-retry-first"))
            XCTFail("Expected first recorder Stop to fail")
        } catch {
            XCTAssertEqual(
                error as? SegmentSpeechCoordinatorError,
                .captureFailed(.captureFinalizationFailed)
            )
        }
        XCTAssertEqual(coordinator.snapshot.segments[0].lifecycle, .finalizationAuthorized)
        XCTAssertNil(coordinator.snapshot.segments[0].captureFailureReason)

        let recovered = try await coordinator.finalizeSegment(
            commandID: CommandID("stop-retry-second")
        )
        XCTAssertEqual(recovered.segments[0].lifecycle, .audioReady)
        XCTAssertEqual(recorder.finishCount(), 2)
    }

    func testNonPlayableFinalizationPreservesEvidenceAndAllowsNewSegmentWithoutRelaunch() async throws {
        let nonPlayable = try capturedAudio(
            fileName: "non-playable-source.m4a",
            isPlayable: false,
            byteCount: 0,
            decodedDurationMilliseconds: 0
        )
        let store = InMemorySessionManifestStore()
        let recorder = StubSegmentRecorder(capture: nonPlayable)
        let transcriber = SequencedSegmentTranscriber(results: [])
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("non-playable-session"),
            activityID: "non-playable-activity",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: recorder,
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential")
        )
        _ = try await coordinator.giveCandidateFloor(commandID: CommandID("non-playable-floor"))
        _ = try await coordinator.beginSegment(commandID: CommandID("non-playable-begin"))

        let finalized = try await coordinator.finalizeSegment(
            commandID: CommandID("non-playable-finalize")
        )
        let failed = try XCTUnwrap(finalized.segments.first)
        XCTAssertEqual(failed.lifecycle, .failed)
        XCTAssertEqual(failed.captureFailureReason, .noPlayableAudio)
        XCTAssertEqual(failed.capturedAudio, nonPlayable)
        let durable = await store.load(sessionID: finalized.sessionID)
        XCTAssertEqual(durable?.segments.first?.capturedAudio, nonPlayable)

        let next = try await coordinator.beginSegment(
            commandID: CommandID("non-playable-next-begin")
        )
        XCTAssertEqual(next.segments.count, 2)
        XCTAssertEqual(next.segments[0].lifecycle, .failed)
        XCTAssertEqual(next.segments[1].lifecycle, .recording)
        let providerCalls = await transcriber.invocationCount()
        XCTAssertEqual(providerCalls, 0)
    }

    func testCompatibilityFinishTranscribesTheActiveSegmentNotOlderAudio() async throws {
        let recorder = StubSegmentRecorder(
            capture: try capturedAudio(fileName: "compatibility-active.m4a")
        )
        let transcriber = SequencedSegmentTranscriber(
            results: [
                .success(
                    SegmentTranscriptionResult(body: "second segment only", quality: .verified)
                )
            ]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("compatibility-active-session"),
            activityID: "compatibility-active-activity",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: fixtureRuntime(),
            recording: recorder,
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential")
        )
        _ = try await coordinator.giveCandidateFloor(commandID: CommandID("compatibility-floor"))
        let firstRecording = try await coordinator.beginSegment(
            commandID: CommandID("compatibility-first-begin")
        )
        let firstID = try XCTUnwrap(firstRecording.segments.first?.id)
        _ = try await coordinator.finalizeSegment(commandID: CommandID("compatibility-first-stop"))

        let secondRecording = try await coordinator.beginSegment(
            commandID: CommandID("compatibility-second-begin")
        )
        let secondID = try XCTUnwrap(secondRecording.segments.last?.id)
        let completed = try await coordinator.finishSegment(
            commandID: CommandID("compatibility-second-stop"),
            transcriptionCommandID: CommandID("compatibility-second-transcribe")
        )

        let first = try XCTUnwrap(completed.segments.first { $0.id == firstID })
        let second = try XCTUnwrap(completed.segments.first { $0.id == secondID })
        XCTAssertTrue(first.transcriptionAttempts.isEmpty)
        XCTAssertEqual(second.selectedCandidate?.body, "second segment only")
    }

    func testMicStartPersistenceFailureStopsAndPreservesCapture() async throws {
        let store = FailingRevisionSessionManifestStore(
            failingRevision: 3,
            failureCount: 2
        )
        let capture = try capturedAudio(
            fileName: "start-persistence-recovery.m4a",
            isPartial: true
        )
        let recorder = StubSegmentRecorder(
            capture: capture,
            recovery: capture,
            finishSucceedsOnlyOnce: true
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("start-persistence-session"),
            activityID: "start-persistence-activity",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: recorder,
            transcriber: SequencedSegmentTranscriber(results: []),
            credentialReader: FixedCredentialReader(value: "credential")
        )
        _ = try await coordinator.giveCandidateFloor(commandID: CommandID("start-persistence-floor"))

        do {
            _ = try await coordinator.beginSegment(commandID: CommandID("start-persistence-begin"))
            XCTFail("Expected injected recording-start persistence failure")
        } catch {
            XCTAssertEqual(error as? InjectedStoreError, .writeFailed)
        }

        XCTAssertEqual(recorder.beginCount(), 1)
        XCTAssertEqual(recorder.finishCount(), 1)
        XCTAssertEqual(coordinator.snapshot.segments[0].lifecycle, .captureAuthorized)

        let recovered = try await coordinator.finalizeSegment(
            commandID: CommandID("start-persistence-explicit-stop")
        )
        XCTAssertEqual(recorder.finishCount(), 2)
        XCTAssertEqual(recorder.recoveryCount(), 1)
        XCTAssertEqual(recovered.segments[0].lifecycle, .audioReady)
        XCTAssertEqual(
            recovered.segments[0].capturedAudio?.audioIdentity.fileName,
            "start-persistence-recovery.m4a"
        )
        let durable = await store.load(sessionID: coordinator.snapshot.sessionID)
        XCTAssertEqual(durable?.segments[0].lifecycle, .audioReady)
    }

    func testManualAndCueOnlyNeverInvokeSemanticEndpointClassifier() async throws {
        for mode in [TurnMode.manual, .cueOnly] {
            let classifier = RecordingSemanticEndpointClassifier(
                results: [
                    .success(
                        SemanticEndpointProposal(
                            decision: .likelyEnd,
                            reasonCode: .answerResolvesQuestion
                        )
                    )
                ]
            )
            let coordinator = try await SegmentSpeechCoordinator.open(
                sessionID: SessionID("endpoint-off-\(mode.rawValue)"),
                activityID: "endpoint-off-activity",
                activityPrompt: try fixtureActivityPrompt(),
                turnMode: mode,
                manifestStore: InMemorySessionManifestStore(),
                interviewerRuntime: fixtureRuntime(),
                recording: StubSegmentRecorder(
                    capture: try capturedAudio(fileName: "endpoint-off.m4a")
                ),
                transcriber: SequencedSegmentTranscriber(
                    results: [
                        .success(
                            SegmentTranscriptionResult(
                                body: "A durable manual answer.",
                                quality: .verified
                            )
                        )
                    ]
                ),
                credentialReader: FixedCredentialReader(value: "credential"),
                semanticEndpointClassifier: classifier
            )
            _ = try await coordinator.giveCandidateFloor(
                commandID: CommandID("endpoint-off-floor-\(mode.rawValue)")
            )
            _ = try await coordinator.beginSegment(
                commandID: CommandID("endpoint-off-begin-\(mode.rawValue)")
            )
            let completed = try await coordinator.finishSegment(
                commandID: CommandID("endpoint-off-finish-\(mode.rawValue)"),
                transcriptionCommandID: CommandID("endpoint-off-transcribe-\(mode.rawValue)")
            )

            let classifierCalls = await classifier.invocationCount()
            XCTAssertEqual(classifierCalls, 0)
            XCTAssertTrue(completed.endpointEvaluations.isEmpty)
            XCTAssertEqual(completed.phase, .candidateFloor)
            XCTAssertTrue(completed.turns.isEmpty)
        }
    }

    func testPatientAutoPersistsAuthorizationBeforeExactShadowContextAndProposal() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(
            store: store,
            turnMode: .patientAuto
        )
        _ = try await makeTranscribedSegment(
            session: session,
            commandStem: "endpoint-first",
            body: "  first spoken part  ",
            quality: .verified
        )
        let restored = await session.snapshot()
        let classifier = RecordingSemanticEndpointClassifier(
            results: [
                .success(
                    SemanticEndpointProposal(
                        decision: .likelyContinue,
                        reasonCode: .requestedPartUnanswered
                    )
                )
            ],
            authorizationStore: store,
            sessionID: restored.sessionID
        )
        let interviewerRuntime = CountingInterviewerRuntime()
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: restored.sessionID,
            activityID: restored.activityID,
            activityPrompt: restored.activityPrompt,
            manifestStore: store,
            interviewerRuntime: interviewerRuntime,
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-second.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(
                results: [
                    .success(
                        SegmentTranscriptionResult(
                            body: "\n second spoken part \n",
                            quality: .verified
                        )
                    )
                ]
            ),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-second-begin")
        )
        let completed = try await coordinator.finishSegment(
            commandID: CommandID("endpoint-second-finish"),
            transcriptionCommandID: CommandID("endpoint-second-transcribe")
        )

        let contexts = await classifier.recordedContexts()
        let context = try XCTUnwrap(contexts.first)
        XCTAssertEqual(context.interviewerQuestion, restored.activityPrompt.question)
        XCTAssertEqual(context.requestedParts, restored.activityPrompt.requestedParts)
        XCTAssertEqual(context.accumulatedAnswer, "first spoken part\n\nsecond spoken part")
        XCTAssertEqual(context.latestSegment, "second spoken part")
        XCTAssertEqual(context.silenceDurationMilliseconds, 0)
        XCTAssertEqual(context.specialty, "system_design")
        XCTAssertEqual(context.stage, restored.activityPrompt.stage)
        XCTAssertFalse(context.explicitCue)
        XCTAssertTrue(context.workspaceActivity.isEmpty)

        let authorizationStates = await classifier.authorizationStatesAtEntry()
        XCTAssertEqual(authorizationStates, [true])
        let evaluation = try XCTUnwrap(completed.endpointEvaluations.last)
        XCTAssertEqual(evaluation.lifecycle, .proposalStored)
        XCTAssertEqual(
            evaluation.proposal,
            SemanticEndpointProposal(
                decision: .likelyContinue,
                reasonCode: .requestedPartUnanswered
            )
        )
        let selectedCandidateIDs = completed.segments
            .filter { $0.committedTurnID == nil && $0.lifecycle != .excluded }
            .sorted { $0.ordinal < $1.ordinal }
            .compactMap(\.selectedCandidateID)
        XCTAssertEqual(evaluation.selectedCandidateIDs, selectedCandidateIDs)
        XCTAssertNil(evaluation.questionTurnID)
        XCTAssertEqual(completed.phase, .candidateFloor)
        XCTAssertTrue(completed.turns.isEmpty)
        let interviewerCalls = await interviewerRuntime.invocationCount()
        XCTAssertEqual(interviewerCalls, 0)
    }

    func testPatientAutoLaterFloorUsesLatestCanonicalInterviewerQuestionAndRestoresMode() async throws {
        let store = InMemorySessionManifestStore()
        let classifier = RecordingSemanticEndpointClassifier(
            results: [
                .success(
                    SemanticEndpointProposal(
                        decision: .likelyEnd,
                        reasonCode: .answerResolvesQuestion
                    )
                ),
                .success(
                    SemanticEndpointProposal(
                        decision: .likelyContinue,
                        reasonCode: .unfinishedThought
                    )
                ),
            ]
        )
        let runtime = CountingInterviewerRuntime()
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("endpoint-later-floor"),
            activityID: "endpoint-later-floor-activity",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: .patientAuto,
            manifestStore: store,
            interviewerRuntime: runtime,
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-later-floor.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(
                results: [
                    .success(
                        SegmentTranscriptionResult(
                            body: "Initial answer.",
                            quality: .verified
                        )
                    ),
                    .success(
                        SegmentTranscriptionResult(
                            body: "Later-floor answer.",
                            quality: .verified
                        )
                    ),
                ]
            ),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("endpoint-later-floor-initial-floor")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-later-floor-first-begin")
        )
        _ = try await coordinator.finishSegment(
            commandID: CommandID("endpoint-later-floor-first-finish"),
            transcriptionCommandID: CommandID("endpoint-later-floor-first-transcribe")
        )
        let interviewerTurn = try await coordinator.handOff(
            commandID: CommandID("endpoint-later-floor-hand-off")
        )
        guard case .interviewer(let canonicalQuestion) = interviewerTurn.turns.last else {
            return XCTFail("Expected the canonical Interviewer Turn")
        }
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("endpoint-later-floor-second-floor")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-later-floor-second-begin")
        )
        let completed = try await coordinator.finishSegment(
            commandID: CommandID("endpoint-later-floor-second-finish"),
            transcriptionCommandID: CommandID("endpoint-later-floor-second-transcribe")
        )

        let contexts = await classifier.recordedContexts()
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts[1].interviewerQuestion, canonicalQuestion.displayMarkdown)
        XCTAssertEqual(contexts[1].requestedParts, [])
        XCTAssertEqual(contexts[1].accumulatedAnswer, "Later-floor answer.")
        XCTAssertEqual(completed.endpointEvaluations.last?.questionTurnID, canonicalQuestion.id)

        let restored = try await SegmentSpeechCoordinator.open(
            sessionID: completed.sessionID,
            activityID: completed.activityID,
            activityPrompt: completed.activityPrompt,
            manifestStore: store,
            interviewerRuntime: runtime,
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-later-floor-restore.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(results: []),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        XCTAssertEqual(restored.snapshot.turnMode, .patientAuto)
    }

    func testPatientAutoStoresSafeClassifierFailureWithoutFailingTranscription() async throws {
        let classifier = RecordingSemanticEndpointClassifier(
            results: [.failure(.rejected(statusCode: 429))]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("endpoint-safe-failure"),
            activityID: "endpoint-safe-failure-activity",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: .patientAuto,
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-safe-failure.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(
                results: [
                    .success(
                        SegmentTranscriptionResult(
                            body: "The transcript succeeds independently.",
                            quality: .verified
                        )
                    )
                ]
            ),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("endpoint-safe-failure-floor")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-safe-failure-begin")
        )

        let completed = try await coordinator.finishSegment(
            commandID: CommandID("endpoint-safe-failure-finish"),
            transcriptionCommandID: CommandID("endpoint-safe-failure-transcribe")
        )

        XCTAssertEqual(
            completed.segments.first?.selectedCandidate?.body,
            "The transcript succeeds independently."
        )
        let evaluation = try XCTUnwrap(completed.endpointEvaluations.first)
        XCTAssertEqual(evaluation.lifecycle, .failed)
        XCTAssertEqual(evaluation.failure?.reason, .providerRejected)
        XCTAssertEqual(evaluation.failure?.providerStatusCode, 429)
        XCTAssertNil(evaluation.proposal)
        XCTAssertEqual(completed.phase, .candidateFloor)
    }

    func testPatientAutoAuthorizationPersistenceFailureKeepsSuccessfulTranscript() async throws {
        let store = EndpointWriteFailingSessionManifestStore(failurePoint: .authorization)
        let classifier = RecordingSemanticEndpointClassifier(
            results: [
                .success(
                    SemanticEndpointProposal(
                        decision: .likelyEnd,
                        reasonCode: .answerResolvesQuestion
                    )
                )
            ]
        )
        let transcriber = SequencedSegmentTranscriber(
            results: [
                .success(
                    SegmentTranscriptionResult(
                        body: "The transcript remains the successful operation.",
                        quality: .verified
                    )
                )
            ]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("endpoint-authorization-write-failure"),
            activityID: "endpoint-authorization-write-failure-activity",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: .patientAuto,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-authorization-write-failure.m4a")
            ),
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("endpoint-authorization-write-failure-floor")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-authorization-write-failure-begin")
        )

        let completed = try await coordinator.finishSegment(
            commandID: CommandID("endpoint-authorization-write-failure-finish"),
            transcriptionCommandID: CommandID("endpoint-authorization-write-failure-transcribe")
        )

        XCTAssertEqual(
            completed.segments.first?.selectedCandidate?.body,
            "The transcript remains the successful operation."
        )
        XCTAssertTrue(completed.endpointEvaluations.isEmpty)
        let classifierCalls = await classifier.invocationCount()
        let transcriptionCalls = await transcriber.invocationCount()
        XCTAssertEqual(classifierCalls, 0)
        XCTAssertEqual(transcriptionCalls, 1)
        let durable = await store.load(sessionID: completed.sessionID)
        XCTAssertEqual(durable?.revision, completed.revision)
        XCTAssertEqual(durable?.segments, completed.segments)
        XCTAssertEqual(durable?.endpointEvaluations, completed.endpointEvaluations)
    }

    func testPatientAutoOutcomePersistenceFailureReconcilesAuthorization() async throws {
        let store = EndpointWriteFailingSessionManifestStore(failurePoint: .outcome)
        let classifier = RecordingSemanticEndpointClassifier(
            results: [
                .success(
                    SemanticEndpointProposal(
                        decision: .likelyEnd,
                        reasonCode: .answerResolvesQuestion
                    )
                )
            ]
        )
        let transcriber = SequencedSegmentTranscriber(
            results: [
                .success(
                    SegmentTranscriptionResult(
                        body: "The transcript survives Shadow persistence recovery.",
                        quality: .verified
                    )
                )
            ]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("endpoint-outcome-write-failure"),
            activityID: "endpoint-outcome-write-failure-activity",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: .patientAuto,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-outcome-write-failure.m4a")
            ),
            transcriber: transcriber,
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("endpoint-outcome-write-failure-floor")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-outcome-write-failure-begin")
        )

        let completed = try await coordinator.finishSegment(
            commandID: CommandID("endpoint-outcome-write-failure-finish"),
            transcriptionCommandID: CommandID("endpoint-outcome-write-failure-transcribe")
        )

        XCTAssertEqual(
            completed.segments.first?.selectedCandidate?.body,
            "The transcript survives Shadow persistence recovery."
        )
        let evaluation = try XCTUnwrap(completed.endpointEvaluations.first)
        XCTAssertEqual(evaluation.lifecycle, .failed)
        XCTAssertEqual(evaluation.failure?.reason, .interrupted)
        XCTAssertNil(evaluation.proposal)
        let classifierCalls = await classifier.invocationCount()
        let transcriptionCalls = await transcriber.invocationCount()
        XCTAssertEqual(classifierCalls, 1)
        XCTAssertEqual(transcriptionCalls, 1)
        let durable = await store.load(sessionID: completed.sessionID)
        XCTAssertEqual(durable?.revision, completed.revision)
        XCTAssertEqual(durable?.segments, completed.segments)
        XCTAssertEqual(durable?.endpointEvaluations, completed.endpointEvaluations)
    }

    func testInFlightProposalBecomesInterruptedAfterConcurrentHandOff() async throws {
        let classifier = SuspendedSemanticEndpointClassifier(
            proposal: SemanticEndpointProposal(
                decision: .likelyEnd,
                reasonCode: .answerResolvesQuestion
            )
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("endpoint-concurrent-handoff"),
            activityID: "endpoint-concurrent-handoff-activity",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: .patientAuto,
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-concurrent-handoff.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(
                results: [
                    .success(
                        SegmentTranscriptionResult(
                            body: "This answer is handed off while classification is pending.",
                            quality: .verified
                        )
                    )
                ]
            ),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("endpoint-concurrent-handoff-floor")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-concurrent-handoff-begin")
        )

        let finishing = Task { @MainActor in
            try await coordinator.finishSegment(
                commandID: CommandID("endpoint-concurrent-handoff-finish"),
                transcriptionCommandID: CommandID("endpoint-concurrent-handoff-transcribe")
            )
        }
        await classifier.waitUntilInvoked()
        let handedOff = try await coordinator.handOff(
            commandID: CommandID("endpoint-concurrent-handoff-turn")
        )
        XCTAssertEqual(handedOff.phase, .interviewerTurn)
        await classifier.resume()

        let completed = try await finishing.value
        let evaluation = try XCTUnwrap(completed.endpointEvaluations.first)
        XCTAssertEqual(completed.phase, .interviewerTurn)
        XCTAssertEqual(evaluation.lifecycle, .failed)
        XCTAssertEqual(evaluation.failure?.reason, .interrupted)
        XCTAssertNil(evaluation.proposal)
    }

    func testPatientAutoMapsClassifierErrorsToSafeDurableFailures() async throws {
        let cases: [(
            name: String,
            error: GroqEndpointClassifierError,
            expectedReason: EndpointEvaluationFailureReason
        )] = [
            ("missing", .missingCredential, .missingCredential),
            ("transport", .transportFailure, .transportFailure),
            ("malformed", .malformedResponse, .invalidResponse),
            (
                "context-limit",
                .contextLimitExceeded(.accumulatedAnswer),
                .contextRejected
            ),
        ]

        for testCase in cases {
            let classifier = RecordingSemanticEndpointClassifier(
                results: [.failure(testCase.error)]
            )
            let coordinator = try await SegmentSpeechCoordinator.open(
                sessionID: SessionID("endpoint-safe-\(testCase.name)"),
                activityID: "endpoint-safe-\(testCase.name)-activity",
                activityPrompt: try fixtureActivityPrompt(),
                turnMode: .patientAuto,
                manifestStore: InMemorySessionManifestStore(),
                interviewerRuntime: fixtureRuntime(),
                recording: StubSegmentRecorder(
                    capture: try capturedAudio(
                        fileName: "endpoint-safe-\(testCase.name).m4a"
                    )
                ),
                transcriber: SequencedSegmentTranscriber(
                    results: [
                        .success(
                            SegmentTranscriptionResult(
                                body: "Durable transcript for \(testCase.name).",
                                quality: .verified
                            )
                        )
                    ]
                ),
                credentialReader: FixedCredentialReader(value: "credential"),
                semanticEndpointClassifier: classifier
            )
            _ = try await coordinator.giveCandidateFloor(
                commandID: CommandID("endpoint-safe-\(testCase.name)-floor")
            )
            _ = try await coordinator.beginSegment(
                commandID: CommandID("endpoint-safe-\(testCase.name)-begin")
            )

            let completed = try await coordinator.finishSegment(
                commandID: CommandID("endpoint-safe-\(testCase.name)-finish"),
                transcriptionCommandID: CommandID(
                    "endpoint-safe-\(testCase.name)-transcribe"
                )
            )

            XCTAssertEqual(completed.phase, .candidateFloor, testCase.name)
            XCTAssertEqual(
                completed.segments.first?.selectedCandidate?.body,
                "Durable transcript for \(testCase.name).",
                testCase.name
            )
            XCTAssertNotNil(completed.segments.first?.capturedAudio, testCase.name)
            let evaluation = try XCTUnwrap(
                completed.endpointEvaluations.first,
                testCase.name
            )
            XCTAssertEqual(evaluation.lifecycle, .failed, testCase.name)
            XCTAssertEqual(evaluation.failure?.reason, testCase.expectedReason, testCase.name)
            XCTAssertNil(evaluation.failure?.providerStatusCode, testCase.name)
            XCTAssertNil(evaluation.proposal, testCase.name)
        }
    }

    func testEndpointEvaluationPersistsEveryValidDecisionReasonPairObservationally() async throws {
        let pairs: [SemanticEndpointProposal] = [
            .init(decision: .likelyEnd, reasonCode: .explicitHandoffCue),
            .init(decision: .likelyEnd, reasonCode: .answerResolvesQuestion),
            .init(decision: .likelyContinue, reasonCode: .unfinishedThought),
            .init(decision: .likelyContinue, reasonCode: .requestedPartUnanswered),
            .init(decision: .likelyContinue, reasonCode: .recentWorkspaceActivity),
            .init(decision: .ambiguous, reasonCode: .insufficientEvidence),
        ]
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(
            store: store,
            turnMode: .patientAuto
        )
        let segmentID = try await makeTranscribedSegment(
            session: session,
            commandStem: "endpoint-valid-pairs",
            body: "Durable evidence remains on the Candidate Floor.",
            quality: .verified
        )
        let selected = await session.snapshot()
        let selectedCandidateIDs = selected.segments
            .filter { $0.committedTurnID == nil && $0.lifecycle != .excluded }
            .sorted { $0.ordinal < $1.ordinal }
            .compactMap(\.selectedCandidateID)

        for (index, proposal) in pairs.enumerated() {
            let authorizationCommandID = CommandID("endpoint-valid-pair-\(index)-authorization")
            let authorized = try await session.apply(
                .authorizeEndpointEvaluation(
                    commandID: authorizationCommandID,
                    triggerSegmentID: segmentID,
                    selectedCandidateIDs: selectedCandidateIDs,
                    questionTurnID: nil,
                    contextFingerprint: "sha256:v1:\(String(repeating: String(index), count: 64))"
                )
            )
            XCTAssertEqual(authorized.disposition, .accepted)
            let evaluation = try XCTUnwrap(
                authorized.snapshot.endpointEvaluations.first {
                    $0.authorizationCommandID == authorizationCommandID
                }
            )
            let recorded = try await session.execute(
                .recordEndpointEvaluationOutcome(
                    commandID: CommandID("endpoint-valid-pair-\(index)-outcome"),
                    evaluationID: evaluation.id,
                    outcome: .proposal(proposal)
                )
            )

            XCTAssertEqual(recorded.endpointEvaluations.last?.lifecycle, .proposalStored)
            XCTAssertEqual(recorded.endpointEvaluations.last?.proposal, proposal)
            XCTAssertEqual(recorded.phase, .candidateFloor)
            XCTAssertTrue(recorded.turns.isEmpty)
            XCTAssertNil(recorded.segments.first?.committedTurnID)
        }
    }

    func testPatientAutoSkipsEvaluationWhenAnotherDraftSegmentIsUnresolved() async throws {
        let classifier = RecordingSemanticEndpointClassifier(
            results: [
                .success(
                    SemanticEndpointProposal(
                        decision: .ambiguous,
                        reasonCode: .insufficientEvidence
                    )
                )
            ]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("endpoint-unresolved-draft"),
            activityID: "endpoint-unresolved-draft-activity",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: .patientAuto,
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-unresolved-draft.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(
                results: [
                    .success(
                        SegmentTranscriptionResult(
                            body: "The later Segment still transcribes.",
                            quality: .verified
                        )
                    )
                ]
            ),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("endpoint-unresolved-floor")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-unresolved-first-begin")
        )
        _ = try await coordinator.finalizeSegment(
            commandID: CommandID("endpoint-unresolved-first-finish")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-unresolved-second-begin")
        )

        let completed = try await coordinator.finishSegment(
            commandID: CommandID("endpoint-unresolved-second-finish"),
            transcriptionCommandID: CommandID("endpoint-unresolved-second-transcribe")
        )

        XCTAssertEqual(completed.segments[0].lifecycle, .audioReady)
        XCTAssertNil(completed.segments[0].selectedCandidate)
        XCTAssertEqual(
            completed.segments[1].selectedCandidate?.body,
            "The later Segment still transcribes."
        )
        XCTAssertTrue(completed.endpointEvaluations.isEmpty)
        let classifierCalls = await classifier.invocationCount()
        XCTAssertEqual(classifierCalls, 0)
    }

    func testPatientAutoEvaluatesOnlyWhenRetryChangesSelectedEvidence() async throws {
        let classifier = RecordingSemanticEndpointClassifier(
            results: [
                .success(
                    SemanticEndpointProposal(
                        decision: .likelyEnd,
                        reasonCode: .answerResolvesQuestion
                    )
                )
            ]
        )
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("endpoint-selected-retry"),
            activityID: "endpoint-selected-retry-activity",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: .manual,
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-selected-retry.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(
                results: [
                    .success(
                        SegmentTranscriptionResult(
                            body: "Selected best-available answer.",
                            quality: .bestAvailable
                        )
                    ),
                    .success(
                        SegmentTranscriptionResult(
                            body: "A lower-quality retry must stay observationally silent.",
                            quality: .possibleContamination
                        )
                    ),
                    .success(
                        SegmentTranscriptionResult(
                            body: "  Newly selected verified answer.  ",
                            quality: .verified
                        )
                    ),
                ]
            ),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("endpoint-selected-retry-floor")
        )
        _ = try await coordinator.beginSegment(
            commandID: CommandID("endpoint-selected-retry-begin")
        )
        let initial = try await coordinator.finishSegment(
            commandID: CommandID("endpoint-selected-retry-finish"),
            transcriptionCommandID: CommandID("endpoint-selected-retry-initial")
        )
        let segmentID = try XCTUnwrap(initial.segments.first?.id)
        let initiallySelectedID = try XCTUnwrap(initial.segments.first?.selectedCandidateID)
        XCTAssertTrue(initial.endpointEvaluations.isEmpty)

        _ = try await coordinator.setTurnMode(
            .patientAuto,
            commandID: CommandID("endpoint-selected-retry-mode")
        )
        let lowerQuality = try await coordinator.transcribeSegment(
            segmentID: segmentID,
            commandID: CommandID("endpoint-selected-retry-lower")
        )
        XCTAssertEqual(lowerQuality.segments.first?.selectedCandidateID, initiallySelectedID)
        XCTAssertTrue(lowerQuality.endpointEvaluations.isEmpty)
        let callsAfterLowerQualityRetry = await classifier.invocationCount()
        XCTAssertEqual(callsAfterLowerQualityRetry, 0)

        let higherQuality = try await coordinator.transcribeSegment(
            segmentID: segmentID,
            commandID: CommandID("endpoint-selected-retry-higher")
        )
        XCTAssertNotEqual(higherQuality.segments.first?.selectedCandidateID, initiallySelectedID)
        XCTAssertEqual(higherQuality.endpointEvaluations.count, 1)
        let contexts = await classifier.recordedContexts()
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.accumulatedAnswer, "Newly selected verified answer.")
        XCTAssertEqual(contexts.first?.latestSegment, "Newly selected verified answer.")
    }

    func testResumeMarksAuthorizedEndpointEvaluationInterruptedWithoutProviderReplay() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(
            store: store,
            turnMode: .patientAuto
        )
        let segmentID = try await makeTranscribedSegment(
            session: session,
            commandStem: "endpoint-interrupted",
            body: "Durable selected evidence.",
            quality: .verified
        )
        let selectedSnapshot = await session.snapshot()
        let selectedCandidateIDs = selectedSnapshot.segments
            .filter { $0.committedTurnID == nil && $0.lifecycle != .excluded }
            .sorted { $0.ordinal < $1.ordinal }
            .compactMap(\.selectedCandidateID)
        _ = try await session.execute(
            .authorizeEndpointEvaluation(
                commandID: CommandID("endpoint-interrupted-authorization"),
                triggerSegmentID: segmentID,
                selectedCandidateIDs: selectedCandidateIDs,
                questionTurnID: nil,
                contextFingerprint: "sha256:v1:\(String(repeating: "a", count: 64))"
            )
        )
        let classifier = RecordingSemanticEndpointClassifier(results: [])
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: selectedSnapshot.sessionID,
            activityID: selectedSnapshot.activityID,
            activityPrompt: selectedSnapshot.activityPrompt,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-interrupted-unused.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(results: []),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )

        let reconciled = try await coordinator.resumePendingWork()

        let evaluation = try XCTUnwrap(reconciled.endpointEvaluations.first)
        XCTAssertEqual(evaluation.lifecycle, .failed)
        XCTAssertEqual(evaluation.failure?.reason, .interrupted)
        let classifierCalls = await classifier.invocationCount()
        XCTAssertEqual(classifierCalls, 0)
    }

    func testResumeDoesNotFabricateMissingEndpointBoundaryOrCallProvider() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makeCandidateFloorSession(
            store: store,
            turnMode: .patientAuto
        )
        _ = try await makeTranscribedSegment(
            session: session,
            commandStem: "endpoint-preauthorization-crash",
            body: "Transcript persisted before authorization.",
            quality: .verified
        )
        let snapshot = await session.snapshot()
        let classifier = RecordingSemanticEndpointClassifier(results: [])
        let coordinator = try await SegmentSpeechCoordinator.open(
            sessionID: snapshot.sessionID,
            activityID: snapshot.activityID,
            activityPrompt: snapshot.activityPrompt,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime(),
            recording: StubSegmentRecorder(
                capture: try capturedAudio(fileName: "endpoint-preauthorization-unused.m4a")
            ),
            transcriber: SequencedSegmentTranscriber(results: []),
            credentialReader: FixedCredentialReader(value: "credential"),
            semanticEndpointClassifier: classifier
        )

        let resumed = try await coordinator.resumePendingWork()

        XCTAssertTrue(resumed.endpointEvaluations.isEmpty)
        let classifierCalls = await classifier.invocationCount()
        XCTAssertEqual(classifierCalls, 0)
    }

    func testRestoreRejectsDuplicateCandidateTurnIDsWithoutTrapping() async throws {
        let duplicateID = TurnID("duplicate-candidate-id")
        let first = CandidateTurn(
            id: duplicateID,
            commandID: CommandID("first-candidate"),
            transcript: CandidateTranscript(body: "first", quality: .verified)
        )
        let second = CandidateTurn(
            id: duplicateID,
            commandID: CommandID("second-candidate"),
            transcript: CandidateTranscript(body: "second", quality: .verified)
        )
        let turns: [InterviewTurn] = [
            .candidate(first),
            .interviewer(
                InterviewerTurn(
                    id: TurnID("first-interviewer"),
                    commandID: first.commandID,
                    replyToTurnID: duplicateID,
                    response: CanonicalInterviewerResponse(
                        displayMarkdown: "First response",
                        spokenText: "First response"
                    )
                )
            ),
            .candidate(second),
            .interviewer(
                InterviewerTurn(
                    id: TurnID("second-interviewer"),
                    commandID: second.commandID,
                    replyToTurnID: duplicateID,
                    response: CanonicalInterviewerResponse(
                        displayMarkdown: "Second response",
                        spokenText: "Second response"
                    )
                )
            ),
        ]
        let manifest = SessionManifest(
            sessionID: SessionID("duplicate-candidate-session"),
            activityID: "duplicate-candidate-activity",
            activityPrompt: try fixtureActivityPrompt(),
            phase: .interviewerTurn,
            turnMode: .manual,
            turns: turns,
            revision: 1,
            appliedCommands: []
        )

        do {
            _ = try await InterviewRoomSession.restore(
                sessionID: manifest.sessionID,
                manifestStore: InMemorySessionManifestStore(manifests: [manifest]),
                interviewerRuntime: fixtureRuntime()
            )
            XCTFail("Expected duplicate Candidate Turn IDs to be rejected")
        } catch let error as InterviewRoomSessionError {
            XCTAssertEqual(error, .invalidManifest(reason: "duplicate Candidate Turn IDs"))
        }
    }

    private func makeCandidateFloorSession(
        store: InMemorySessionManifestStore,
        turnMode: TurnMode = .manual
    ) async throws -> InterviewRoomSession {
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("session-\(UUID().uuidString)"),
            activityID: "activity-segment-fixture",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: turnMode,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime()
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("floor-\(UUID().uuidString)"))
        )
        return session
    }

    private func fixtureRuntime() -> DeterministicInterviewerRuntime {
        DeterministicInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "What trade-off comes next?",
                spokenText: "What trade-off comes next?"
            )
        )
    }

    private func fixtureActivityPrompt() throws -> ActivityPrompt {
        try ActivityPrompt(
            specialty: .systemDesign,
            stage: "High-level design",
            question: "Design a global notification system.",
            requestedParts: ["Explain delivery reliability and tradeoffs."]
        )
    }

    private func makeTranscribedSegment(
        session: InterviewRoomSession,
        commandStem: String,
        body: String,
        quality: TranscriptQuality
    ) async throws -> SegmentID {
        let snapshot = try await session.execute(
            .beginSegment(commandID: CommandID("\(commandStem)-begin"))
        )
        let segmentID = try XCTUnwrap(snapshot.segments.last?.id)
        try await makeAudioReady(
            session: session,
            segmentID: segmentID,
            commandStem: commandStem
        )
        try await recordCandidate(
            session: session,
            segmentID: segmentID,
            commandStem: "\(commandStem)-attempt",
            kind: .initial,
            body: body,
            quality: quality,
            credential: "credential"
        )
        return segmentID
    }

    private func makeAudioReady(
        session: InterviewRoomSession,
        segmentID: SegmentID,
        commandStem: String
    ) async throws {
        _ = try await session.execute(
            .recordSegmentCaptureOutcome(
                commandID: CommandID("\(commandStem)-recording"),
                segmentID: segmentID,
                outcome: .recordingStarted
            )
        )
        _ = try await session.execute(
            .finalizeSegment(
                commandID: CommandID("\(commandStem)-finalize"),
                segmentID: segmentID
            )
        )
        _ = try await session.execute(
            .recordSegmentCaptureOutcome(
                commandID: CommandID("\(commandStem)-audio"),
                segmentID: segmentID,
                outcome: .finalized(
                    try capturedAudio(fileName: "\(commandStem)-audio.m4a")
                )
            )
        )
    }

    private func makeAudioReadySegment(
        session: InterviewRoomSession,
        commandStem: String
    ) async throws -> SegmentID {
        let snapshot = try await session.execute(
            .beginSegment(commandID: CommandID("\(commandStem)-begin"))
        )
        let segmentID = try XCTUnwrap(snapshot.segments.last?.id)
        try await makeAudioReady(
            session: session,
            segmentID: segmentID,
            commandStem: commandStem
        )
        return segmentID
    }

    private func recordCandidate(
        session: InterviewRoomSession,
        segmentID: SegmentID,
        commandStem: String,
        kind: SegmentTranscriptionKind,
        body: String,
        quality: TranscriptQuality,
        credential: String
    ) async throws {
        let authorized = try await session.execute(
            .authorizeSegmentTranscription(
                commandID: CommandID("\(commandStem)-authorization"),
                segmentID: segmentID,
                kind: kind,
                credentialFingerprint: credentialFingerprint(credential)
            )
        )
        let segment = try XCTUnwrap(authorized.segments.first { $0.id == segmentID })
        let attempt = try XCTUnwrap(segment.transcriptionAttempts.last)
        _ = try await session.execute(
            .recordSegmentTranscriptionOutcome(
                commandID: CommandID("\(commandStem)-outcome"),
                segmentID: segmentID,
                attemptID: attempt.id,
                outcome: .candidate(
                    SegmentTranscriptionResult(body: body, quality: quality)
                )
            )
        )
    }

    private func credentialFingerprint(_ value: String) -> String {
        InterviewRoomSession.credentialFingerprint(value)
    }

    private func capturedAudio(
        fileName: String,
        isPartial: Bool = false,
        integrityReasons: [SegmentIntegrityReason] = [],
        isPlayable: Bool = true,
        byteCount: Int64 = 4_096,
        decodedDurationMilliseconds: Int64 = 1_000
    ) throws -> CapturedAudioSegment {
        CapturedAudioSegment(
            audioIdentity: try SegmentAudioIdentity(validating: fileName),
            startedAtMilliseconds: 1_000,
            endedAtMilliseconds: 2_000,
            durationMilliseconds: 1_000,
            decodedDurationMilliseconds: decodedDurationMilliseconds,
            byteCount: byteCount,
            isPlayable: isPlayable,
            isPartial: isPartial,
            integrityReasons: integrityReasons
        )
    }
}

@MainActor
private final class StubSegmentRecorder: SegmentRecording {
    private let capture: CapturedAudioSegment
    private let recovery: CapturedAudioSegment?
    private var unexpectedTerminationHandler: (@MainActor @Sendable () -> Void)?
    private var recoveries = 0
    private var begins = 0
    private var finishes = 0
    private var finishFailuresRemaining: Int
    private let finishSucceedsOnlyOnce: Bool

    init(
        capture: CapturedAudioSegment,
        recovery: CapturedAudioSegment? = nil,
        finishFailuresRemaining: Int = 0,
        finishSucceedsOnlyOnce: Bool = false
    ) {
        self.capture = capture
        self.recovery = recovery
        self.finishFailuresRemaining = finishFailuresRemaining
        self.finishSucceedsOnlyOnce = finishSucceedsOnlyOnce
    }

    func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        unexpectedTerminationHandler = handler
    }

    func beginCapture(_ request: SegmentCaptureRequest) async throws {
        begins += 1
    }

    func finishCapture() async throws -> CapturedAudioSegment {
        finishes += 1
        if finishFailuresRemaining > 0 {
            finishFailuresRemaining -= 1
            throw StubRecorderError.finishFailed
        }
        if finishSucceedsOnlyOnce, finishes > 1 {
            throw StubRecorderError.finishFailed
        }
        return capture
    }

    func recoverCapture(
        _ request: SegmentCaptureRequest
    ) async throws -> CapturedAudioSegment? {
        recoveries += 1
        return recovery
    }

    func playbackURL(
        sessionID: SessionID,
        audioIdentity: SegmentAudioIdentity
    ) async throws -> URL {
        URL(fileURLWithPath: "/private/tmp/\(audioIdentity.fileName)")
    }

    func recoveryCount() -> Int { recoveries }
    func beginCount() -> Int { begins }
    func finishCount() -> Int { finishes }

    func triggerUnexpectedTermination() {
        unexpectedTerminationHandler?()
    }
}

@MainActor
private final class SnapshotObserver {
    private(set) var lifecycles: [CandidateSegmentLifecycle] = []
    private let completed: XCTestExpectation
    private var didComplete = false

    init(completed: XCTestExpectation) {
        self.completed = completed
    }

    func receive(_ snapshot: InterviewRoomSnapshot) {
        guard let lifecycle = snapshot.segments.first?.lifecycle else { return }
        lifecycles.append(lifecycle)
        if lifecycle == .audioReady, !didComplete {
            didComplete = true
            completed.fulfill()
        }
    }
}

private actor SequencedSegmentTranscriber: SegmentTranscribing {
    private var results: [Result<SegmentTranscriptionResult, SegmentTranscriptionAdapterFailure>]
    private var calls = 0

    init(
        results: [Result<SegmentTranscriptionResult, SegmentTranscriptionAdapterFailure>]
    ) {
        self.results = results
    }

    func transcribe(
        _ request: SegmentTranscriptionRequest,
        credential: String
    ) throws -> SegmentTranscriptionResult {
        calls += 1
        guard !results.isEmpty else {
            throw SegmentTranscriptionAdapterFailure(reason: .providerUnavailable)
        }
        return try results.removeFirst().get()
    }

    func invocationCount() -> Int { calls }
}

private actor RecordingSemanticEndpointClassifier: SemanticEndpointClassifying {
    private var results: [Result<SemanticEndpointProposal, GroqEndpointClassifierError>]
    private let authorizationStore: InMemorySessionManifestStore?
    private let sessionID: SessionID?
    private var contexts: [SemanticEndpointContext] = []
    private var authorizationStates: [Bool] = []

    init(
        results: [Result<SemanticEndpointProposal, GroqEndpointClassifierError>],
        authorizationStore: InMemorySessionManifestStore? = nil,
        sessionID: SessionID? = nil
    ) {
        self.results = results
        self.authorizationStore = authorizationStore
        self.sessionID = sessionID
    }

    func classify(
        _ context: SemanticEndpointContext
    ) async throws -> SemanticEndpointProposal {
        contexts.append(context)
        if let authorizationStore, let sessionID {
            let manifest = await authorizationStore.load(sessionID: sessionID)
            authorizationStates.append(
                manifest?.endpointEvaluations.last?.lifecycle == .authorized
            )
        }
        guard !results.isEmpty else {
            throw GroqEndpointClassifierError.transportFailure
        }
        return try results.removeFirst().get()
    }

    func invocationCount() -> Int { contexts.count }
    func recordedContexts() -> [SemanticEndpointContext] { contexts }
    func authorizationStatesAtEntry() -> [Bool] { authorizationStates }
}

private actor SuspendedSemanticEndpointClassifier: SemanticEndpointClassifying {
    private let proposal: SemanticEndpointProposal
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<SemanticEndpointProposal, Never>?

    init(proposal: SemanticEndpointProposal) {
        self.proposal = proposal
    }

    func classify(
        _ context: SemanticEndpointContext
    ) async throws -> SemanticEndpointProposal {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilInvoked() async {
        if didEnter { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func resume() {
        resultContinuation?.resume(returning: proposal)
        resultContinuation = nil
    }
}

private actor CountingInterviewerRuntime: InterviewerRuntime {
    private var calls = 0

    func respond(
        to request: InterviewerRequest
    ) -> CanonicalInterviewerResponse {
        calls += 1
        return CanonicalInterviewerResponse(
            displayMarkdown: "What trade-off comes next?",
            spokenText: "What trade-off comes next?"
        )
    }

    func invocationCount() -> Int { calls }
}

private struct FixedCredentialReader: GroqCredentialReading {
    let value: String

    func readGroqCredential() -> String { value }
}

private enum StubRecorderError: Error {
    case finishFailed
}

private enum InjectedStoreError: Error, Equatable {
    case writeFailed
}

private actor FailingRevisionSessionManifestStore: SessionManifestStore {
    private var manifests: [SessionID: SessionManifest] = [:]
    private let failingRevision: Int
    private var failuresRemaining: Int

    init(failingRevision: Int, failureCount: Int = 1) {
        self.failingRevision = failingRevision
        failuresRemaining = failureCount
    }

    func load(sessionID: SessionID) -> SessionManifest? {
        manifests[sessionID]
    }

    func save(
        _ manifest: SessionManifest,
        expectedRevision: Int?
    ) throws {
        if manifest.revision == failingRevision, failuresRemaining > 0 {
            failuresRemaining -= 1
            throw InjectedStoreError.writeFailed
        }
        let current = manifests[manifest.sessionID]
        guard current?.revision == expectedRevision else {
            throw SessionManifestStoreError.revisionConflict(
                expected: expectedRevision,
                actual: current?.revision
            )
        }
        manifests[manifest.sessionID] = manifest
    }
}

private enum EndpointWriteFailurePoint {
    case authorization
    case outcome
}

private actor EndpointWriteFailingSessionManifestStore: SessionManifestStore {
    private var manifests: [SessionID: SessionManifest] = [:]
    private let failurePoint: EndpointWriteFailurePoint
    private var didFail = false

    init(failurePoint: EndpointWriteFailurePoint) {
        self.failurePoint = failurePoint
    }

    func load(sessionID: SessionID) -> SessionManifest? {
        manifests[sessionID]
    }

    func save(
        _ manifest: SessionManifest,
        expectedRevision: Int?
    ) throws {
        let current = manifests[manifest.sessionID]
        guard current?.revision == expectedRevision else {
            throw SessionManifestStoreError.revisionConflict(
                expected: expectedRevision,
                actual: current?.revision
            )
        }
        let isAuthorization = current?.endpointEvaluations.count
            != manifest.endpointEvaluations.count
            && manifest.endpointEvaluations.last?.lifecycle == .authorized
        let isOutcome = current?.endpointEvaluations.last?.lifecycle == .authorized
            && manifest.endpointEvaluations.last?.lifecycle != .authorized
        let shouldFail = switch failurePoint {
        case .authorization: isAuthorization
        case .outcome: isOutcome
        }
        if shouldFail, !didFail {
            didFail = true
            throw InjectedStoreError.writeFailed
        }
        manifests[manifest.sessionID] = manifest
    }
}
