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
            activityPrompt: try fixtureActivityPrompt(),
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
        let requests = await runtime.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.activityPrompt, try fixtureActivityPrompt())
        XCTAssertEqual(request.candidateTurn, candidate)
        XCTAssertTrue(request.priorVisibleTurns.isEmpty)
        XCTAssertEqual(request.responseTurnID, interviewer.id)

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

    func testActivityPromptValidationAndDecodingPreserveAcceptedCopyVerbatim() throws {
        let prompt = try ActivityPrompt(
            specialty: .systemDesign,
            stage: "  High-level design  ",
            question: "  Design a globally distributed queue.\n",
            requestedParts: ["  Clarify durability.  ", "Discuss failover.\n"]
        )
        let encoded = try JSONEncoder().encode(prompt)

        XCTAssertEqual(try JSONDecoder().decode(ActivityPrompt.self, from: encoded), prompt)
        XCTAssertEqual(prompt.specialty.rawValue, "system_design")
        XCTAssertEqual(prompt.stage, "  High-level design  ")
        XCTAssertEqual(prompt.question, "  Design a globally distributed queue.\n")
        XCTAssertEqual(prompt.requestedParts[0], "  Clarify durability.  ")

        XCTAssertThrowsError(
            try ActivityPrompt(
                specialty: .systemDesign,
                stage: " \n",
                question: "Question",
                requestedParts: []
            )
        ) { error in
            XCTAssertEqual(error as? ActivityPromptValidationError, .emptyStage)
        }
        XCTAssertThrowsError(
            try ActivityPrompt(
                specialty: .systemDesign,
                stage: "Stage",
                question: " \n",
                requestedParts: []
            )
        ) { error in
            XCTAssertEqual(error as? ActivityPromptValidationError, .emptyQuestion)
        }
        XCTAssertThrowsError(
            try ActivityPrompt(
                specialty: .systemDesign,
                stage: "Stage",
                question: "Question",
                requestedParts: ["One", " \n"]
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivityPromptValidationError,
                .emptyRequestedPart(index: 1)
            )
        }
        XCTAssertThrowsError(
            try ActivityPrompt(
                specialty: .systemDesign,
                stage: "Stage",
                question: "Question",
                requestedParts: Array(
                    repeating: "Part",
                    count: ActivityPrompt.maximumRequestedParts + 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ActivityPromptValidationError,
                .tooManyRequestedParts(maximum: ActivityPrompt.maximumRequestedParts)
            )
        }

        let unknownSpecialty = Data(
            #"{"specialty":"behavioral","stage":"Stage","question":"Question","requestedParts":[]}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ActivityPrompt.self, from: unknownSpecialty)
        )
    }

    func testRuntimeRequestUsesExactCandidateBoundPromptAndBoundedRecentVisibleHistory() async throws {
        let store = InMemorySessionManifestStore()
        let prompt = try fixtureActivityPrompt()
        let runtime = CountingInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "Follow up.",
                spokenText: "Follow up."
            )
        )
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("bounded-visible-history"),
            activityID: "activity-bounded-visible-history",
            activityPrompt: prompt,
            manifestStore: store,
            interviewerRuntime: runtime
        )
        var snapshot = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("history-floor-0"))
        )

        for index in 0..<7 {
            snapshot = try await session.execute(
                .handOff(
                    commandID: CommandID("history-handoff-\(index)"),
                    transcript: CandidateTranscript(
                        body: "Prior candidate answer \(index).",
                        quality: .verified
                    )
                )
            )
            snapshot = try await session.execute(
                .giveCandidateFloor(commandID: CommandID("history-floor-\(index + 1)"))
            )
        }

        let visibleBeforeFinalHandOff = snapshot.turns
        let exactCandidate = "  Exact durable answer.\nSecond line.  "
        let completed = try await session.execute(
            .handOff(
                commandID: CommandID("history-final-handoff"),
                transcript: CandidateTranscript(
                    body: exactCandidate,
                    quality: .bestAvailable
                )
            )
        )

        let requests = await runtime.requests()
        let finalRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(finalRequest.activityPrompt, prompt)
        XCTAssertEqual(finalRequest.candidateTurn.transcript.body, exactCandidate)
        XCTAssertEqual(
            finalRequest.priorVisibleTurns,
            Array(visibleBeforeFinalHandOff.suffix(InterviewerRequest.maximumPriorVisibleTurns))
        )
        XCTAssertEqual(
            finalRequest.priorVisibleTurns.count,
            InterviewerRequest.maximumPriorVisibleTurns
        )
        guard case .interviewer(let interviewer) = completed.turns.last else {
            return XCTFail("Expected persisted Interviewer Turn")
        }
        XCTAssertEqual(finalRequest.responseTurnID, interviewer.id)
    }

    func testVisibleHistoryByteBudgetDropsWholeOldPairsAndCountsEveryCarriedString() async throws {
        XCTAssertEqual(
            InterviewerRequest.maximumPriorVisibleHistoryUTF8Bytes,
            256 * 1_024
        )
        let runtime = CountingInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: String(repeating: "D", count: 10 * 1_024),
                spokenText: String(repeating: "S", count: 40 * 1_024)
            )
        )
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("byte-bounded-visible-history"),
            activityID: "activity-byte-bounded-visible-history",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: InMemorySessionManifestStore(),
            interviewerRuntime: runtime
        )
        var snapshot = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("byte-history-floor-0"))
        )

        for index in 0..<3 {
            snapshot = try await session.execute(
                .handOff(
                    commandID: CommandID("byte-history-handoff-\(index)"),
                    transcript: CandidateTranscript(
                        body: "\(index)" + String(repeating: "C", count: 70 * 1_024 - 1),
                        quality: .verified
                    )
                )
            )
            snapshot = try await session.execute(
                .giveCandidateFloor(commandID: CommandID("byte-history-floor-\(index + 1)"))
            )
        }

        let priorTurns = snapshot.turns
        _ = try await session.execute(
            .handOff(
                commandID: CommandID("byte-history-final-handoff"),
                transcript: CandidateTranscript(body: "Current answer.", quality: .verified)
            )
        )

        let requests = await runtime.requests()
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.priorVisibleTurns, Array(priorTurns.suffix(4)))
        XCTAssertEqual(request.priorVisibleTurns.count, 4)
        let selectedByteCount = request.priorVisibleTurns.reduce(into: 0) { total, turn in
            switch turn {
            case .candidate(let candidate):
                total += candidate.transcript.body.utf8.count
            case .interviewer(let interviewer):
                total += interviewer.displayMarkdown.utf8.count
                    + interviewer.spokenText.utf8.count
            }
        }
        XCTAssertLessThanOrEqual(
            selectedByteCount,
            InterviewerRequest.maximumPriorVisibleHistoryUTF8Bytes
        )
        guard case .candidate(let oldestSelected) = request.priorVisibleTurns.first else {
            return XCTFail("Expected history to start on a complete Candidate/Interviewer pair")
        }
        XCTAssertTrue(oldestSelected.transcript.body.hasPrefix("1"))
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
            activityPrompt: try fixtureActivityPrompt(),
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

    func testOversizedCandidateIsRejectedBeforeTurnPersistenceOrRuntimeInvocation() async throws {
        XCTAssertEqual(CandidateTranscript.maximumBodyUTF8Bytes, 256 * 1_024)
        let store = InMemorySessionManifestStore()
        let runtime = CountingInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "Must remain unused.",
                spokenText: "Must remain unused."
            )
        )
        let sessionID = SessionID("oversized-pending-candidate")
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-oversized-pending-candidate",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: store,
            interviewerRuntime: runtime
        )
        let candidateFloor = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("oversized-candidate-floor"))
        )

        do {
            _ = try await session.execute(
                .handOff(
                    commandID: CommandID("oversized-candidate-handoff"),
                    transcript: CandidateTranscript(
                        body: String(
                            repeating: "C",
                            count: CandidateTranscript.maximumBodyUTF8Bytes + 1
                        ),
                        quality: .verified
                    )
                )
            )
            XCTFail("Expected oversized Candidate transcript to fail closed")
        } catch {
            XCTAssertEqual(
                error as? InterviewRoomSessionError,
                .candidateTranscriptTooLong(
                    maximumUTF8Bytes: CandidateTranscript.maximumBodyUTF8Bytes
                )
            )
        }

        let current = await session.snapshot()
        XCTAssertEqual(current, candidateFloor)
        XCTAssertTrue(current.turns.isEmpty)
        let durable = try await store.load(sessionID: sessionID)
        XCTAssertEqual(durable?.revision, candidateFloor.revision)
        XCTAssertTrue(durable?.turns.isEmpty == true)
        let invocationCount = await runtime.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testProviderFailurePersistsCandidateAndRetryAuthorizationBeforeEachAttempt() async throws {
        let store = InMemorySessionManifestStore()
        let sessionID = SessionID("session-provider-failure")
        let failingRuntime = CountingFailingInterviewerRuntime()
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-provider-failure",
            activityPrompt: try fixtureActivityPrompt(),
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
        let callsBeforeExplicitRetry = await retryRuntime.invocationCount()
        XCTAssertEqual(callsBeforeExplicitRetry, 0)

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
        let retryRequests = await retryRuntime.requests()
        XCTAssertEqual(retryRequests.count, 2)
        XCTAssertEqual(retryRequests[0].candidateTurn, preservedCandidate)
        XCTAssertEqual(retryRequests[1].candidateTurn, preservedCandidate)
        XCTAssertEqual(retryRequests[0].responseTurnID, retryRequests[1].responseTurnID)
        XCTAssertEqual(retryRequests[1].responseTurnID, recoveredInterviewer.id)
        XCTAssertEqual(retryRequests[0].activityPrompt, try fixtureActivityPrompt())
    }

    func testOversizedCanonicalResponseStaysUnpublishedUntilFreshValidRetry() async throws {
        XCTAssertEqual(
            CanonicalInterviewerResponse.maximumDisplayMarkdownUTF8Bytes,
            128 * 1_024
        )
        XCTAssertEqual(
            CanonicalInterviewerResponse.maximumSpokenTextUTF8Bytes,
            64 * 1_024
        )
        let store = InMemorySessionManifestStore()
        let runtime = SequencedInterviewerRuntime(
            results: [
                .success(
                    CanonicalInterviewerResponse(
                        displayMarkdown: String(
                            repeating: "D",
                            count: CanonicalInterviewerResponse
                                .maximumDisplayMarkdownUTF8Bytes + 1
                        ),
                        spokenText: "Oversized display response."
                    )
                ),
                .success(
                    CanonicalInterviewerResponse(
                        displayMarkdown: "Oversized spoken response.",
                        spokenText: String(
                            repeating: "S",
                            count: CanonicalInterviewerResponse
                                .maximumSpokenTextUTF8Bytes + 1
                        )
                    )
                ),
                .success(
                    CanonicalInterviewerResponse(
                        displayMarkdown: "Valid **bounded** response.",
                        spokenText: "Valid bounded response."
                    )
                ),
            ]
        )
        let sessionID = SessionID("oversized-canonical-response")
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-oversized-canonical-response",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: store,
            interviewerRuntime: runtime
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("oversized-response-floor"))
        )

        do {
            _ = try await session.execute(
                .handOff(
                    commandID: CommandID("oversized-response-handoff"),
                    transcript: CandidateTranscript(body: "Durable answer.", quality: .verified)
                )
            )
            XCTFail("Expected oversized display Markdown to remain unpublished")
        } catch {
            XCTAssertEqual(error as? InterviewRoomSessionError, .invalidInterviewerResponse)
        }
        let afterDisplayFailure = await session.snapshot()
        XCTAssertEqual(afterDisplayFailure.phase, .interviewerProcessing)
        XCTAssertEqual(afterDisplayFailure.revision, 2)
        XCTAssertEqual(afterDisplayFailure.turns.count, 1)

        do {
            _ = try await session.execute(
                .retryInterviewerResponse(commandID: CommandID("oversized-spoken-retry"))
            )
            XCTFail("Expected oversized spoken text to remain unpublished")
        } catch {
            XCTAssertEqual(error as? InterviewRoomSessionError, .invalidInterviewerResponse)
        }
        let afterSpokenFailure = await session.snapshot()
        XCTAssertEqual(afterSpokenFailure.phase, .interviewerProcessing)
        XCTAssertEqual(afterSpokenFailure.revision, 3)
        XCTAssertEqual(afterSpokenFailure.turns.count, 1)
        let durablePending = try await store.load(sessionID: sessionID)
        XCTAssertEqual(durablePending?.turns, afterSpokenFailure.turns)

        let completed = try await session.execute(
            .retryInterviewerResponse(commandID: CommandID("bounded-response-retry"))
        )
        XCTAssertEqual(completed.phase, .interviewerTurn)
        XCTAssertEqual(completed.revision, 5)
        XCTAssertEqual(completed.turns.count, 2)
        let invocationCount = await runtime.invocationCount()
        XCTAssertEqual(invocationCount, 3)
    }

    func testMalformedResponseStaysProcessingAndRequiresFreshExplicitRetryAfterRestore() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = SequencedInterviewerRuntime(
            results: [
                .success(
                    CanonicalInterviewerResponse(
                        displayMarkdown: " \n",
                        spokenText: "Malformed output must not publish."
                    )
                ),
                .success(
                    CanonicalInterviewerResponse(
                        displayMarkdown: "Persisted **canonical** response.",
                        spokenText: "Persisted canonical response."
                    )
                ),
            ]
        )
        let sessionID = SessionID("malformed-runtime-response")
        let session = try await InterviewRoomSession.start(
            sessionID: sessionID,
            activityID: "activity-malformed-runtime-response",
            activityPrompt: try fixtureActivityPrompt(),
            manifestStore: store,
            interviewerRuntime: runtime
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("malformed-floor"))
        )
        let handOff = InterviewRoomCommand.handOff(
            commandID: CommandID("malformed-handoff"),
            transcript: CandidateTranscript(
                body: "Keep this candidate answer exactly.",
                quality: .verified
            )
        )

        do {
            _ = try await session.execute(handOff)
            XCTFail("Expected whitespace display Markdown to be rejected")
        } catch {
            XCTAssertEqual(error as? InterviewRoomSessionError, .invalidInterviewerResponse)
        }
        let pending = await session.snapshot()
        XCTAssertEqual(pending.phase, .interviewerProcessing)
        XCTAssertEqual(pending.turns.count, 1)
        let callsAfterMalformedResponse = await runtime.invocationCount()
        XCTAssertEqual(callsAfterMalformedResponse, 1)

        let restored = try await InterviewRoomSession.restore(
            sessionID: sessionID,
            manifestStore: store,
            interviewerRuntime: runtime
        )
        let callsAfterRestore = await runtime.invocationCount()
        XCTAssertEqual(callsAfterRestore, 1, "restore must not replay provider work")

        let duplicate = try await restored.execute(handOff)
        XCTAssertEqual(duplicate, pending)
        let callsAfterDuplicateHandOff = await runtime.invocationCount()
        XCTAssertEqual(
            callsAfterDuplicateHandOff,
            1,
            "the accepted Hand off identity cannot authorize another runtime turn"
        )

        let completed = try await restored.execute(
            .retryInterviewerResponse(commandID: CommandID("malformed-explicit-retry"))
        )
        XCTAssertEqual(completed.phase, .interviewerTurn)
        XCTAssertEqual(completed.revision, 4)
        let callsAfterFreshRetry = await runtime.invocationCount()
        XCTAssertEqual(callsAfterFreshRetry, 2)
        guard case .candidate(let candidate) = completed.turns[0],
              case .interviewer(let interviewer) = completed.turns[1] else {
            return XCTFail("Expected one canonical persisted turn pair")
        }
        XCTAssertEqual(candidate.transcript.body, "Keep this candidate answer exactly.")
        XCTAssertFalse(
            interviewer.displayMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        XCTAssertFalse(
            interviewer.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )

        let requests = await runtime.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].candidateTurn, requests[1].candidateTurn)
        XCTAssertEqual(requests[0].responseTurnID, requests[1].responseTurnID)
        XCTAssertEqual(requests[1].responseTurnID, interviewer.id)
    }

    func testRestoreRejectsDurableTurnWithEmptyCanonicalResponse() async throws {
        let candidate = CandidateTurn(
            id: TurnID("restore-malformed-candidate"),
            commandID: CommandID("restore-malformed-handoff"),
            transcript: CandidateTranscript(body: "Durable candidate.", quality: .verified)
        )
        let manifest = SessionManifest(
            sessionID: SessionID("restore-malformed-response"),
            activityID: "activity-restore-malformed-response",
            activityPrompt: try fixtureActivityPrompt(),
            phase: .interviewerTurn,
            turnMode: .manual,
            turns: [
                .candidate(candidate),
                .interviewer(
                    InterviewerTurn(
                        id: TurnID("restore-malformed-interviewer"),
                        commandID: candidate.commandID,
                        replyToTurnID: candidate.id,
                        response: CanonicalInterviewerResponse(
                            displayMarkdown: "Valid display copy.",
                            spokenText: " \n"
                        )
                    )
                ),
            ],
            revision: 1,
            appliedCommands: []
        )

        do {
            _ = try await InterviewRoomSession.restore(
                sessionID: manifest.sessionID,
                manifestStore: InMemorySessionManifestStore(manifests: [manifest]),
                interviewerRuntime: DeterministicInterviewerRuntime(
                    response: CanonicalInterviewerResponse(
                        displayMarkdown: "Unused.",
                        spokenText: "Unused."
                    )
                )
            )
            XCTFail("Expected malformed durable response to be rejected")
        } catch let error as InterviewRoomSessionError {
            guard case .invalidManifest = error else {
                return XCTFail("Expected invalidManifest, received \(error)")
            }
        }
    }

    func testRestoreRejectsOversizedDurableCandidateAndCanonicalFields() async throws {
        let prompt = try fixtureActivityPrompt()
        let oversizedCandidate = CandidateTurn(
            id: TurnID("restore-oversized-candidate"),
            commandID: CommandID("restore-oversized-candidate-command"),
            transcript: CandidateTranscript(
                body: String(
                    repeating: "C",
                    count: CandidateTranscript.maximumBodyUTF8Bytes + 1
                ),
                quality: .verified
            )
        )
        try await assertRestoreRejects(
            SessionManifest(
                sessionID: SessionID("restore-oversized-candidate-session"),
                activityID: "activity-restore-oversized-candidate",
                activityPrompt: prompt,
                phase: .interviewerProcessing,
                turnMode: .manual,
                turns: [.candidate(oversizedCandidate)],
                revision: 1,
                appliedCommands: []
            )
        )

        let validCandidate = CandidateTurn(
            id: TurnID("restore-bounded-candidate"),
            commandID: CommandID("restore-bounded-candidate-command"),
            transcript: CandidateTranscript(body: "Bounded candidate.", quality: .verified)
        )
        try await assertRestoreRejects(
            SessionManifest(
                sessionID: SessionID("restore-oversized-display-session"),
                activityID: "activity-restore-oversized-display",
                activityPrompt: prompt,
                phase: .interviewerTurn,
                turnMode: .manual,
                turns: [
                    .candidate(validCandidate),
                    .interviewer(
                        InterviewerTurn(
                            id: TurnID("restore-oversized-display"),
                            commandID: validCandidate.commandID,
                            replyToTurnID: validCandidate.id,
                            response: CanonicalInterviewerResponse(
                                displayMarkdown: String(
                                    repeating: "D",
                                    count: CanonicalInterviewerResponse
                                        .maximumDisplayMarkdownUTF8Bytes + 1
                                ),
                                spokenText: "Bounded spoken text."
                            )
                        )
                    ),
                ],
                revision: 1,
                appliedCommands: []
            )
        )
        try await assertRestoreRejects(
            SessionManifest(
                sessionID: SessionID("restore-oversized-spoken-session"),
                activityID: "activity-restore-oversized-spoken",
                activityPrompt: prompt,
                phase: .interviewerTurn,
                turnMode: .manual,
                turns: [
                    .candidate(validCandidate),
                    .interviewer(
                        InterviewerTurn(
                            id: TurnID("restore-oversized-spoken"),
                            commandID: validCandidate.commandID,
                            replyToTurnID: validCandidate.id,
                            response: CanonicalInterviewerResponse(
                                displayMarkdown: "Bounded display Markdown.",
                                spokenText: String(
                                    repeating: "S",
                                    count: CanonicalInterviewerResponse
                                        .maximumSpokenTextUTF8Bytes + 1
                                )
                            )
                        )
                    ),
                ],
                revision: 1,
                appliedCommands: []
            )
        )
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
            activityPrompt: try fixtureActivityPrompt(),
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
            activityPrompt: try fixtureActivityPrompt(),
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
            activityPrompt: try fixtureActivityPrompt(),
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

    private func fixtureActivityPrompt() throws -> ActivityPrompt {
        try ActivityPrompt(
            specialty: .systemDesign,
            stage: "High-level design",
            question: "Design a global notification system.",
            requestedParts: [
                "Clarify scope and requirements.",
                "Propose the high-level architecture and data flow.",
                "Explain delivery reliability and tradeoffs.",
            ]
        )
    }

    private func assertRestoreRejects(
        _ manifest: SessionManifest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await InterviewRoomSession.restore(
                sessionID: manifest.sessionID,
                manifestStore: InMemorySessionManifestStore(manifests: [manifest]),
                interviewerRuntime: DeterministicInterviewerRuntime(
                    response: CanonicalInterviewerResponse(
                        displayMarkdown: "Unused.",
                        spokenText: "Unused."
                    )
                )
            )
            XCTFail("Expected oversized durable content to be rejected", file: file, line: line)
        } catch let error as InterviewRoomSessionError {
            guard case .invalidManifest = error else {
                return XCTFail(
                    "Expected invalidManifest, received \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
}

private enum TurnIDFixtureError: Error {
    case missingCandidate
}

private actor CountingInterviewerRuntime: InterviewerRuntime {
    private let responseValue: CanonicalInterviewerResponse
    private var calls = 0
    private var recordedRequests: [InterviewerRequest] = []

    init(response: CanonicalInterviewerResponse) {
        responseValue = response
    }

    func respond(to request: InterviewerRequest) -> CanonicalInterviewerResponse {
        calls += 1
        recordedRequests.append(request)
        return responseValue
    }

    func invocationCount() -> Int { calls }
    func requests() -> [InterviewerRequest] { recordedRequests }
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
    private var recordedRequests: [InterviewerRequest] = []

    init(results: [Result<CanonicalInterviewerResponse, RuntimeFixtureError>]) {
        self.results = results
    }

    func respond(to request: InterviewerRequest) throws -> CanonicalInterviewerResponse {
        calls += 1
        recordedRequests.append(request)
        guard !results.isEmpty else {
            throw RuntimeFixtureError.unavailable
        }
        return try results.removeFirst().get()
    }

    func invocationCount() -> Int { calls }
    func requests() -> [InterviewerRequest] { recordedRequests }
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
