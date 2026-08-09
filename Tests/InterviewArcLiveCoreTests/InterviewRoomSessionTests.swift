import Foundation
import XCTest
@testable import InterviewArcLiveCore

@MainActor
final class InterviewRoomSessionTests: XCTestCase {
    func testPublicInterfacePersistsCandidateThenCanonicalInterviewerPair() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = CountingInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "Compare **availability** and consistency.",
                spokenText: "Compare availability and consistency."
            )
        )
        let sessionID = SessionID("session-fixture-1")
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-system-design-1",
            manifestStore: store,
            interviewerRuntime: runtime
        )

        let initial = await session.snapshot()
        XCTAssertEqual(initial.phase, .ready)
        XCTAssertEqual(initial.revision, 0)

        let floor = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("open-floor-1"))
        )
        XCTAssertEqual(floor.phase, .candidateFloor)
        XCTAssertEqual(floor.revision, 1)

        let verbatim = "I would partition by tenant and keep a durable event log."
        let result = try await session.execute(
            .handOff(
                commandID: CommandID("handoff-1"),
                transcript: CandidateTranscript(
                    body: verbatim,
                    quality: .bestAvailable
                )
            )
        )

        XCTAssertEqual(result.phase, .interviewerTurn)
        XCTAssertEqual(result.revision, 3)
        XCTAssertEqual(result.turns.count, 2)

        guard case .candidate(let candidate) = result.turns[0],
              case .interviewer(let interviewer) = result.turns[1] else {
            return XCTFail("Expected candidate then interviewer ordering")
        }
        XCTAssertEqual(candidate.transcript.body, verbatim)
        XCTAssertEqual(candidate.transcript.quality, .bestAvailable)
        XCTAssertEqual(interviewer.replyToTurnID, candidate.id)
        XCTAssertEqual(interviewer.commandID, candidate.commandID)
        XCTAssertEqual(interviewer.displayMarkdown, "Compare **availability** and consistency.")
        XCTAssertEqual(interviewer.spokenText, "Compare availability and consistency.")
        let invocationCount = await runtime.invocationCount()
        XCTAssertEqual(invocationCount, 1)

        let restored = try await InterviewRoomSession.restore(
            sessionID: sessionID,
            manifestStore: store,
            interviewerRuntime: runtime
        )
        let restoredSnapshot = await restored.snapshot()
        XCTAssertEqual(restoredSnapshot, result)

        let loadedManifest = try await store.load(sessionID: sessionID)
        let durableManifest = try XCTUnwrap(loadedManifest)
        XCTAssertTrue(
            durableManifest.appliedCommands.allSatisfy {
                $0.payloadFingerprint.hasPrefix("sha256:v1:")
                    && !$0.payloadFingerprint.contains(verbatim)
            }
        )
    }

    func testDuplicateCommandIDIsIdempotentAndChangedPayloadIsRejected() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = CountingInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "What fails next?",
                spokenText: "What fails next?"
            )
        )
        let session = try await makeCandidateFloorSession(store: store, runtime: runtime)
        let handoffID = CommandID("handoff-stable")
        let command = InterviewRoomCommand.handOff(
            commandID: handoffID,
            transcript: CandidateTranscript(body: "Use a write-ahead log.", quality: .verified)
        )

        let first = try await session.execute(command)
        let duplicate = try await session.execute(command)

        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(duplicate.revision, 3)
        XCTAssertEqual(duplicate.turns.count, 2)
        let duplicateInvocationCount = await runtime.invocationCount()
        XCTAssertEqual(duplicateInvocationCount, 1)

        do {
            _ = try await session.execute(
                .handOff(
                    commandID: handoffID,
                    transcript: CandidateTranscript(body: "A changed answer.", quality: .verified)
                )
            )
            XCTFail("Expected changed payload under a used command ID to fail")
        } catch {
            XCTAssertEqual(error as? InterviewRoomSessionError, .commandIDReused(handoffID))
        }

        let unchanged = await session.snapshot()
        let finalInvocationCount = await runtime.invocationCount()
        XCTAssertEqual(unchanged, first)
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testTurnIDCanonicalTupleEncodingPreventsDelimiterCollision() async throws {
        // These tuples produced the same ID under the former `session:command:role` format.
        let firstID = try await completedCandidateTurnID(
            sessionID: SessionID("room:a"),
            handoffID: CommandID("b")
        )
        let secondID = try await completedCandidateTurnID(
            sessionID: SessionID("room"),
            handoffID: CommandID("a:b")
        )

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(firstID.rawValue.hasPrefix("turn:sha256:v1:"))
        XCTAssertTrue(secondID.rawValue.hasPrefix("turn:sha256:v1:"))
    }

    func testTranscriptQualityUsesApprovedPersistedVocabulary() throws {
        XCTAssertEqual(TranscriptQuality.verified.rawValue, "verified")
        XCTAssertEqual(TranscriptQuality.bestAvailable.rawValue, "best_available")
        XCTAssertEqual(
            TranscriptQuality.possibleContamination.rawValue,
            "possible_contamination"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(TranscriptQuality.bestAvailable)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"best_available\"")
        XCTAssertEqual(try decoder.decode(TranscriptQuality.self, from: encoded), .bestAvailable)
    }

    func testInvalidTransitionAndEmptyTranscriptLeaveDurableStateUnchanged() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = DeterministicInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "Continue.",
                spokenText: "Continue."
            )
        )
        let sessionID = SessionID("session-invalid-transition")
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-fixture",
            manifestStore: store,
            interviewerRuntime: runtime
        )

        do {
            _ = try await session.execute(
                .handOff(
                    commandID: CommandID("too-early"),
                    transcript: CandidateTranscript(body: "Answer", quality: .verified)
                )
            )
            XCTFail("Expected Hand off outside the Candidate Floor to fail")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .invalidTransition(command: "handOff", phase: .ready)
            )
        }
        let afterInvalidTransition = await session.snapshot()
        let durableAfterInvalidTransition = try await store.load(sessionID: sessionID)
        XCTAssertEqual(afterInvalidTransition.revision, 0)
        XCTAssertEqual(durableAfterInvalidTransition?.revision, 0)

        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("valid-floor"))
        )
        do {
            _ = try await session.execute(
                .handOff(
                    commandID: CommandID("empty-answer"),
                    transcript: CandidateTranscript(body: "  \n", quality: .possibleContamination)
                )
            )
            XCTFail("Expected an empty transcript to fail")
        } catch {
            XCTAssertEqual(error as? InterviewRoomSessionError, .emptyCandidateTranscript)
        }

        let unchanged = await session.snapshot()
        XCTAssertEqual(unchanged.phase, .candidateFloor)
        XCTAssertEqual(unchanged.revision, 1)
        XCTAssertTrue(unchanged.turns.isEmpty)
        let durableAfterEmptyTranscript = try await store.load(sessionID: sessionID)
        XCTAssertEqual(durableAfterEmptyTranscript?.revision, 1)
    }

    func testProviderFailurePersistsCandidateAndRetryAuthorizationBeforeEachAttempt() async throws {
        let store = InMemorySessionManifestStore()
        let sessionID = SessionID("session-provider-failure")
        let failingRuntime = CountingFailingInterviewerRuntime()
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-provider-failure",
            manifestStore: store,
            interviewerRuntime: failingRuntime
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("floor-before-failure"))
        )

        do {
            _ = try await session.execute(
                .handOff(
                    commandID: CommandID("provider-fails"),
                    transcript: CandidateTranscript(
                        body: "Keep this logical answer intact.",
                        quality: .verified
                    )
                )
            )
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertEqual(error as? RuntimeFixtureError, .unavailable)
        }

        let pending = await session.snapshot()
        XCTAssertEqual(pending.phase, .interviewerProcessing)
        XCTAssertEqual(pending.revision, 2)
        XCTAssertEqual(pending.turns.count, 1)
        guard case .candidate(let preservedCandidate) = pending.turns[0] else {
            return XCTFail("Expected the Candidate Turn to survive provider failure")
        }

        let loaded = try await store.load(sessionID: sessionID)
        let durable = try XCTUnwrap(loaded)
        XCTAssertEqual(durable.revision, 2)
        XCTAssertEqual(durable.turns, pending.turns)

        let duplicate = try await session.execute(
            .handOff(
                commandID: CommandID("provider-fails"),
                transcript: CandidateTranscript(
                    body: "Keep this logical answer intact.",
                    quality: .verified
                )
            )
        )
        XCTAssertEqual(duplicate, pending)
        let failureCalls = await failingRuntime.invocationCount()
        XCTAssertEqual(failureCalls, 1, "duplicate Hand off must not silently call the provider")

        let recoveredResponse = CanonicalInterviewerResponse(
            displayMarkdown: "Recovered **once**.",
            spokenText: "Recovered once."
        )
        let retryRuntime = SequencedInterviewerRuntime(
            results: [
                .failure(.unavailable),
                .success(recoveredResponse),
            ]
        )
        let restored = try await InterviewRoomSession.restore(
            sessionID: sessionID,
            manifestStore: store,
            interviewerRuntime: retryRuntime
        )

        let firstRetry = InterviewRoomCommand.retryInterviewerResponse(
            commandID: CommandID("retry-response-1")
        )
        do {
            _ = try await restored.execute(firstRetry)
            XCTFail("Expected the first explicit retry to fail")
        } catch {
            XCTAssertEqual(error as? RuntimeFixtureError, .unavailable)
        }

        let retryPending = await restored.snapshot()
        XCTAssertEqual(retryPending.phase, .interviewerProcessing)
        XCTAssertEqual(retryPending.revision, 3)
        XCTAssertEqual(retryPending.turns, pending.turns)
        let durableRetryPending = try await store.load(sessionID: sessionID)
        XCTAssertEqual(durableRetryPending?.revision, 3)

        let duplicateRetry = try await restored.execute(firstRetry)
        XCTAssertEqual(duplicateRetry, retryPending)
        let callsAfterDuplicate = await retryRuntime.invocationCount()
        XCTAssertEqual(
            callsAfterDuplicate,
            1,
            "the same durable retry ID must not invoke the provider twice"
        )

        let recovered = try await restored.execute(
            .retryInterviewerResponse(commandID: CommandID("retry-response-2"))
        )
        XCTAssertEqual(recovered.revision, 5)
        XCTAssertEqual(recovered.turns.count, 2)
        guard case .candidate(let recoveredCandidate) = recovered.turns[0],
              case .interviewer(let recoveredInterviewer) = recovered.turns[1] else {
            return XCTFail("Expected one recovered Candidate/Interviewer pair")
        }
        XCTAssertEqual(recoveredCandidate, preservedCandidate)
        XCTAssertEqual(recoveredInterviewer.replyToTurnID, preservedCandidate.id)
        XCTAssertEqual(recoveredInterviewer.response, recoveredResponse)
        let totalRetryCalls = await retryRuntime.invocationCount()
        XCTAssertEqual(totalRetryCalls, 2)
    }

    func testPersistenceFailureDoesNotPublishAcceptedTransition() async throws {
        let backingStore = InMemorySessionManifestStore()
        let store = FailAfterCreationStore(backing: backingStore)
        let runtime = DeterministicInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "Unused.",
                spokenText: "Unused."
            )
        )
        let sessionID = SessionID("session-save-failure")
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-save-failure",
            manifestStore: store,
            interviewerRuntime: runtime
        )

        do {
            _ = try await session.execute(
                .giveCandidateFloor(commandID: CommandID("save-fails"))
            )
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? StoreFixtureError, .writeFailed)
        }

        let afterFailure = await session.snapshot()
        let durableAfterFailure = try await backingStore.load(sessionID: sessionID)
        XCTAssertEqual(afterFailure.revision, 0)
        XCTAssertEqual(durableAfterFailure?.revision, 0)
    }

    private func makeCandidateFloorSession(
        store: InMemorySessionManifestStore,
        runtime: CountingInterviewerRuntime
    ) async throws -> InterviewRoomSession {
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("session-idempotency"),
            activityID: "activity-idempotency",
            manifestStore: store,
            interviewerRuntime: runtime
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("open-idempotency-floor"))
        )
        return session
    }

    private func completedCandidateTurnID(
        sessionID: SessionID,
        handoffID: CommandID
    ) async throws -> TurnID {
        let store = InMemorySessionManifestStore()
        let runtime = DeterministicInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "Fixture response.",
                spokenText: "Fixture response."
            )
        )
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-turn-id-fixture",
            manifestStore: store,
            interviewerRuntime: runtime
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("floor-\(sessionID.rawValue)"))
        )
        let snapshot = try await session.execute(
            .handOff(
                commandID: handoffID,
                transcript: CandidateTranscript(body: "Fixture answer.", quality: .verified)
            )
        )
        guard let firstTurn = snapshot.turns.first,
              case .candidate(let candidate) = firstTurn else {
            throw TurnIDFixtureError.missingCandidate
        }
        return candidate.id
    }
}

private enum TurnIDFixtureError: Error {
    case missingCandidate
}

private actor CountingInterviewerRuntime: InterviewerRuntime {
    private let responseValue: CanonicalInterviewerResponse
    private var calls = 0

    init(response: CanonicalInterviewerResponse) {
        responseValue = response
    }

    func respond(to request: InterviewerRequest) -> CanonicalInterviewerResponse {
        calls += 1
        return responseValue
    }

    func invocationCount() -> Int { calls }
}

private enum RuntimeFixtureError: Error, Equatable, Sendable {
    case unavailable
}

private actor CountingFailingInterviewerRuntime: InterviewerRuntime {
    private var calls = 0

    func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse {
        calls += 1
        throw RuntimeFixtureError.unavailable
    }

    func invocationCount() -> Int { calls }
}

private actor SequencedInterviewerRuntime: InterviewerRuntime {
    private var results: [Result<CanonicalInterviewerResponse, RuntimeFixtureError>]
    private var calls = 0

    init(results: [Result<CanonicalInterviewerResponse, RuntimeFixtureError>]) {
        self.results = results
    }

    func respond(to request: InterviewerRequest) throws -> CanonicalInterviewerResponse {
        calls += 1
        guard !results.isEmpty else {
            throw RuntimeFixtureError.unavailable
        }
        return try results.removeFirst().get()
    }

    func invocationCount() -> Int { calls }
}

private enum StoreFixtureError: Error, Equatable {
    case writeFailed
}

private actor FailAfterCreationStore: SessionManifestStore {
    private let backing: InMemorySessionManifestStore

    init(backing: InMemorySessionManifestStore) {
        self.backing = backing
    }

    func load(sessionID: SessionID) async throws -> SessionManifest? {
        try await backing.load(sessionID: sessionID)
    }

    func save(_ manifest: SessionManifest, expectedRevision: Int?) async throws {
        if expectedRevision != nil {
            throw StoreFixtureError.writeFailed
        }
        try await backing.save(manifest, expectedRevision: expectedRevision)
    }
}
