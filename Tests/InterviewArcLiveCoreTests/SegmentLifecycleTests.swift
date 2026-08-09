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
        let durable = try await store.load(sessionID: coordinator.snapshot.sessionID)
        XCTAssertEqual(durable?.segments[0].lifecycle, .audioReady)
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
        store: InMemorySessionManifestStore
    ) async throws -> InterviewRoomSession {
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("session-\(UUID().uuidString)"),
            activityID: "activity-segment-fixture",
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
        integrityReasons: [SegmentIntegrityReason] = []
    ) throws -> CapturedAudioSegment {
        CapturedAudioSegment(
            audioIdentity: try SegmentAudioIdentity(validating: fileName),
            startedAtMilliseconds: 1_000,
            endedAtMilliseconds: 2_000,
            durationMilliseconds: 1_000,
            decodedDurationMilliseconds: 1_000,
            byteCount: 4_096,
            isPlayable: true,
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
