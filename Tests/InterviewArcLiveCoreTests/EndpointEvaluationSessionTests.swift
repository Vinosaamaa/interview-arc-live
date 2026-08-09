import Foundation
import XCTest
@testable import InterviewArcLiveCore

@MainActor
final class EndpointEvaluationSessionTests: XCTestCase {
    func testAuthorizationAndProposalAreDurableWithoutLeavingCandidateFloor() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makePatientAutoSession(store: store)
        let evidence = try await makeTranscribedSegment(
            session: session,
            commandStem: "proposal",
            body: "Use a durable queue and idempotent delivery workers.",
            quality: .verified
        )
        let context = endpointContext(body: evidence.body)
        let fingerprint = try InterviewRoomSession.endpointContextFingerprint(
            context,
            triggerSegmentID: evidence.segmentID,
            selectedCandidateIDs: [evidence.candidateID],
            questionTurnID: nil
        )

        let authorization = try await session.apply(
            .authorizeEndpointEvaluation(
                commandID: CommandID("endpoint-proposal-authorize"),
                triggerSegmentID: evidence.segmentID,
                selectedCandidateIDs: [evidence.candidateID],
                questionTurnID: nil,
                contextFingerprint: fingerprint
            )
        )

        XCTAssertEqual(authorization.disposition, .accepted)
        XCTAssertEqual(authorization.snapshot.phase, .candidateFloor)
        XCTAssertTrue(authorization.snapshot.turns.isEmpty)
        let authorized = try XCTUnwrap(authorization.snapshot.endpointEvaluations.first)
        XCTAssertEqual(authorized.lifecycle, .authorized)
        XCTAssertEqual(authorized.contextFingerprint, fingerprint)
        XCTAssertNil(authorized.proposal)
        XCTAssertNil(authorized.failure)

        let proposal = SemanticEndpointProposal(
            decision: .likelyEnd,
            reasonCode: .answerResolvesQuestion
        )
        let completed = try await session.execute(
            .recordEndpointEvaluationOutcome(
                commandID: CommandID("endpoint-proposal-outcome"),
                evaluationID: authorized.id,
                outcome: .proposal(proposal)
            )
        )

        XCTAssertEqual(completed.phase, .candidateFloor)
        XCTAssertTrue(completed.turns.isEmpty)
        XCTAssertEqual(completed.endpointEvaluations[0].lifecycle, .proposalStored)
        XCTAssertEqual(completed.endpointEvaluations[0].proposal, proposal)
        XCTAssertNil(completed.endpointEvaluations[0].failure)

        let restored = try await InterviewRoomSession.restore(
            sessionID: completed.sessionID,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime()
        )
        let restoredSnapshot = await restored.snapshot()
        XCTAssertEqual(restoredSnapshot, completed)
    }

    func testExactContextDedupesButNewEvidenceIdentityGetsANewFingerprint() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makePatientAutoSession(store: store)
        let initial = try await makeTranscribedSegment(
            session: session,
            commandStem: "identity-initial",
            body: "The same semantic answer.",
            quality: .bestAvailable
        )
        let context = endpointContext(body: initial.body)
        let initialFingerprint = try InterviewRoomSession.endpointContextFingerprint(
            context,
            triggerSegmentID: initial.segmentID,
            selectedCandidateIDs: [initial.candidateID],
            questionTurnID: nil
        )
        let firstAuthorization = InterviewRoomCommand.authorizeEndpointEvaluation(
            commandID: CommandID("identity-first-authorize"),
            triggerSegmentID: initial.segmentID,
            selectedCandidateIDs: [initial.candidateID],
            questionTurnID: nil,
            contextFingerprint: initialFingerprint
        )
        let first = try await session.apply(firstAuthorization)
        let firstEvaluation = try XCTUnwrap(first.snapshot.endpointEvaluations.first)
        _ = try await session.execute(
            .recordEndpointEvaluationOutcome(
                commandID: CommandID("identity-first-outcome"),
                evaluationID: firstEvaluation.id,
                outcome: .proposal(
                    SemanticEndpointProposal(
                        decision: .ambiguous,
                        reasonCode: .insufficientEvidence
                    )
                )
            )
        )
        let beforeSemanticDuplicate = await session.snapshot()

        let semanticDuplicateCommandID = CommandID("identity-duplicate-authorize")
        let semanticDuplicate = try await session.apply(
            .authorizeEndpointEvaluation(
                commandID: semanticDuplicateCommandID,
                triggerSegmentID: initial.segmentID,
                selectedCandidateIDs: [initial.candidateID],
                questionTurnID: nil,
                contextFingerprint: initialFingerprint
            )
        )
        XCTAssertEqual(semanticDuplicate.disposition, .alreadyApplied)
        XCTAssertEqual(semanticDuplicate.snapshot.endpointEvaluations.count, 1)
        XCTAssertEqual(
            semanticDuplicate.snapshot.revision,
            beforeSemanticDuplicate.revision + 1
        )

        let restored = try await InterviewRoomSession.restore(
            sessionID: semanticDuplicate.snapshot.sessionID,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime()
        )
        do {
            _ = try await restored.execute(
                .setTurnMode(
                    commandID: semanticDuplicateCommandID,
                    mode: .manual
                )
            )
            XCTFail("Expected the consumed semantic-dedupe command ID to reject reuse")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .commandIDReused(semanticDuplicateCommandID)
            )
        }

        let replacementCandidateID = try await recordRetryCandidate(
            session: restored,
            segmentID: initial.segmentID,
            commandStem: "identity-replacement",
            body: initial.body,
            quality: .verified
        )
        let replacementFingerprint = try InterviewRoomSession.endpointContextFingerprint(
            context,
            triggerSegmentID: initial.segmentID,
            selectedCandidateIDs: [replacementCandidateID],
            questionTurnID: nil
        )
        XCTAssertNotEqual(replacementFingerprint, initialFingerprint)

        let replacement = try await restored.apply(
            .authorizeEndpointEvaluation(
                commandID: CommandID("identity-replacement-authorize"),
                triggerSegmentID: initial.segmentID,
                selectedCandidateIDs: [replacementCandidateID],
                questionTurnID: nil,
                contextFingerprint: replacementFingerprint
            )
        )
        XCTAssertEqual(replacement.disposition, .accepted)
        XCTAssertEqual(replacement.snapshot.endpointEvaluations.count, 2)
    }

    func testInterruptedAuthorizationReconcilesWithoutCreatingAProposal() async throws {
        let store = InMemorySessionManifestStore()
        let session = try await makePatientAutoSession(store: store)
        let evidence = try await makeTranscribedSegment(
            session: session,
            commandStem: "interrupted",
            body: "Preserve the exact answer before provider work.",
            quality: .verified
        )
        let context = endpointContext(body: evidence.body)
        let fingerprint = try InterviewRoomSession.endpointContextFingerprint(
            context,
            triggerSegmentID: evidence.segmentID,
            selectedCandidateIDs: [evidence.candidateID],
            questionTurnID: nil
        )
        let authorized = try await session.execute(
            .authorizeEndpointEvaluation(
                commandID: CommandID("interrupted-authorize"),
                triggerSegmentID: evidence.segmentID,
                selectedCandidateIDs: [evidence.candidateID],
                questionTurnID: nil,
                contextFingerprint: fingerprint
            )
        )
        let evaluationID = try XCTUnwrap(authorized.endpointEvaluations.first?.id)

        let restored = try await InterviewRoomSession.restore(
            sessionID: authorized.sessionID,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime()
        )
        let beforeReconciliation = await restored.snapshot()
        XCTAssertEqual(beforeReconciliation.endpointEvaluations[0].lifecycle, .authorized)

        let reconciled = try await restored.execute(
            .reconcileInterruptedEndpointEvaluation(
                commandID: CommandID("interrupted-reconcile"),
                evaluationID: evaluationID
            )
        )
        XCTAssertEqual(reconciled.endpointEvaluations[0].lifecycle, .failed)
        XCTAssertEqual(
            reconciled.endpointEvaluations[0].failure,
            EndpointEvaluationFailure(reason: .interrupted)
        )
        XCTAssertNil(reconciled.endpointEvaluations[0].proposal)

        let duplicate = try await restored.apply(
            .reconcileInterruptedEndpointEvaluation(
                commandID: CommandID("interrupted-reconcile"),
                evaluationID: evaluationID
            )
        )
        XCTAssertEqual(duplicate.disposition, .alreadyApplied)
        XCTAssertEqual(duplicate.snapshot.endpointEvaluations.count, 1)
    }

    func testInvalidProposalDoesNotChangeAuthorizedEvaluation() async throws {
        let session = try await makePatientAutoSession(
            store: InMemorySessionManifestStore()
        )
        let evidence = try await makeTranscribedSegment(
            session: session,
            commandStem: "invalid-outcome",
            body: "An unfinished answer.",
            quality: .verified
        )
        let context = endpointContext(body: evidence.body)
        let fingerprint = try InterviewRoomSession.endpointContextFingerprint(
            context,
            triggerSegmentID: evidence.segmentID,
            selectedCandidateIDs: [evidence.candidateID],
            questionTurnID: nil
        )
        let authorized = try await session.execute(
            .authorizeEndpointEvaluation(
                commandID: CommandID("invalid-outcome-authorize"),
                triggerSegmentID: evidence.segmentID,
                selectedCandidateIDs: [evidence.candidateID],
                questionTurnID: nil,
                contextFingerprint: fingerprint
            )
        )
        let evaluationID = try XCTUnwrap(authorized.endpointEvaluations.first?.id)

        do {
            _ = try await session.execute(
                .recordEndpointEvaluationOutcome(
                    commandID: CommandID("invalid-outcome-record"),
                    evaluationID: evaluationID,
                    outcome: .proposal(
                        SemanticEndpointProposal(
                            decision: .likelyEnd,
                            reasonCode: .unfinishedThought
                        )
                    )
                )
            )
            XCTFail("Expected inconsistent proposal to be rejected")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .invalidEndpointEvaluationOutcome
            )
        }

        let unchanged = await session.snapshot()
        XCTAssertEqual(unchanged, authorized)
    }

    private func makePatientAutoSession(
        store: InMemorySessionManifestStore
    ) async throws -> InterviewRoomSession {
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("endpoint-session-\(UUID().uuidString)"),
            activityID: "endpoint-activity",
            activityPrompt: try fixtureActivityPrompt(),
            turnMode: .patientAuto,
            manifestStore: store,
            interviewerRuntime: fixtureRuntime()
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("endpoint-floor-\(UUID().uuidString)"))
        )
        return session
    }

    private func makeTranscribedSegment(
        session: InterviewRoomSession,
        commandStem: String,
        body: String,
        quality: TranscriptQuality
    ) async throws -> EndpointEvidenceFixture {
        let begun = try await session.execute(
            .beginSegment(commandID: CommandID("\(commandStem)-begin"))
        )
        let segmentID = try XCTUnwrap(begun.segments.last?.id)
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
                commandID: CommandID("\(commandStem)-capture"),
                segmentID: segmentID,
                outcome: .finalized(try capturedAudio("\(commandStem).m4a"))
            )
        )
        let candidateID = try await recordCandidate(
            session: session,
            segmentID: segmentID,
            commandStem: "\(commandStem)-transcription",
            kind: .initial,
            body: body,
            quality: quality
        )
        return EndpointEvidenceFixture(
            segmentID: segmentID,
            candidateID: candidateID,
            body: body
        )
    }

    private func recordRetryCandidate(
        session: InterviewRoomSession,
        segmentID: SegmentID,
        commandStem: String,
        body: String,
        quality: TranscriptQuality
    ) async throws -> TranscriptCandidateID {
        try await recordCandidate(
            session: session,
            segmentID: segmentID,
            commandStem: commandStem,
            kind: .retry,
            body: body,
            quality: quality
        )
    }

    private func recordCandidate(
        session: InterviewRoomSession,
        segmentID: SegmentID,
        commandStem: String,
        kind: SegmentTranscriptionKind,
        body: String,
        quality: TranscriptQuality
    ) async throws -> TranscriptCandidateID {
        let authorized = try await session.execute(
            .authorizeSegmentTranscription(
                commandID: CommandID("\(commandStem)-authorize"),
                segmentID: segmentID,
                kind: kind,
                credentialFingerprint: InterviewRoomSession.credentialFingerprint(
                    "public-safe-fixture-key"
                )
            )
        )
        let segment = try XCTUnwrap(authorized.segments.first(where: {
            $0.id == segmentID
        }))
        let attempt = try XCTUnwrap(segment.transcriptionAttempts.last)
        let completed = try await session.execute(
            .recordSegmentTranscriptionOutcome(
                commandID: CommandID("\(commandStem)-outcome"),
                segmentID: segmentID,
                attemptID: attempt.id,
                outcome: .candidate(
                    SegmentTranscriptionResult(body: body, quality: quality)
                )
            )
        )
        let completedSegment = try XCTUnwrap(completed.segments.first(where: {
            $0.id == segmentID
        }))
        return try XCTUnwrap(completedSegment.selectedCandidateID)
    }

    private func capturedAudio(_ fileName: String) throws -> CapturedAudioSegment {
        CapturedAudioSegment(
            audioIdentity: try SegmentAudioIdentity(validating: fileName),
            startedAtMilliseconds: 100,
            endedAtMilliseconds: 2_100,
            durationMilliseconds: 2_000,
            decodedDurationMilliseconds: 2_000,
            byteCount: 8_192,
            isPlayable: true,
            isPartial: false
        )
    }

    private func endpointContext(body: String) -> SemanticEndpointContext {
        SemanticEndpointContext(
            interviewerQuestion: "Design a global notification system.",
            requestedParts: ["Explain reliability."],
            accumulatedAnswer: body,
            latestSegment: body,
            silenceDurationMilliseconds: 0,
            specialty: ActivitySpecialty.systemDesign.rawValue,
            stage: "High-level design",
            explicitCue: false,
            workspaceActivity: []
        )
    }

    private func fixtureActivityPrompt() throws -> ActivityPrompt {
        try ActivityPrompt(
            specialty: .systemDesign,
            stage: "High-level design",
            question: "Design a global notification system.",
            requestedParts: ["Explain reliability."]
        )
    }

    private func fixtureRuntime() -> DeterministicInterviewerRuntime {
        DeterministicInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "What would you test next?",
                spokenText: "What would you test next?"
            )
        )
    }
}

private struct EndpointEvidenceFixture {
    let segmentID: SegmentID
    let candidateID: TranscriptCandidateID
    let body: String
}
