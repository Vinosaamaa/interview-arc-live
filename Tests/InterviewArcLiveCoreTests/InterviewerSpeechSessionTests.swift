import Foundation
import XCTest

@testable import InterviewArcLiveCore

@MainActor
final class InterviewerSpeechSessionTests: XCTestCase {
    func testMaraV1PinsEveryResolvedGenerationOptionInStableFingerprint() throws {
        let profile = InterviewerSpeechProfile.maraV1
        XCTAssertEqual(profile.profileID, "mara-v1")
        XCTAssertEqual(profile.language, "English")
        XCTAssertEqual(
            profile.conditioning,
            "Aiden, calm, precise, warm technical interviewer with natural measured delivery."
        )
        XCTAssertEqual(profile.maxTokens, 1_200)
        XCTAssertEqual(profile.temperature, 0.9)
        XCTAssertEqual(profile.topP, 1.0)
        XCTAssertEqual(profile.topK, 0)
        XCTAssertEqual(profile.minP, 0)
        XCTAssertEqual(profile.repetitionPenalty, 1.05)
        XCTAssertEqual(profile.repetitionContextSize, 20)
        XCTAssertEqual(profile.streamingInterval, 0.32)
        XCTAssertTrue(profile.fingerprint.hasPrefix("sha256:v1:"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                InterviewerSpeechProfile.self,
                from: JSONEncoder().encode(profile)
            ),
            profile
        )

        let changed = try InterviewerSpeechProfile(
            profileID: profile.profileID,
            language: profile.language,
            conditioning: profile.conditioning,
            maxTokens: profile.maxTokens,
            temperature: profile.temperature,
            topP: profile.topP,
            topK: 1,
            minP: profile.minP,
            repetitionPenalty: profile.repetitionPenalty,
            repetitionContextSize: profile.repetitionContextSize,
            streamingInterval: profile.streamingInterval
        )
        XCTAssertNotEqual(changed.fingerprint, profile.fingerprint)
    }

    func testInterviewerTurnAtomicallyCreatesStablePendingUtterance() async throws {
        let (session, store) = try await completedSession(id: "speech-atomic")
        let snapshot = await session.snapshot()

        XCTAssertEqual(snapshot.revision, 3)
        XCTAssertEqual(snapshot.interviewerUtterances.count, 1)
        guard case .interviewer(let turn) = snapshot.turns.last else {
            return XCTFail("Expected canonical Interviewer Turn")
        }
        let utterance = try XCTUnwrap(snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.turnID, turn.id)
        XCTAssertEqual(utterance.lifecycle, .pending)
        XCTAssertTrue(utterance.synthesisAttempts.isEmpty)
        XCTAssertTrue(utterance.spokenTextFingerprint.hasPrefix("sha256:v1:"))
        XCTAssertFalse(utterance.spokenTextFingerprint.contains(turn.spokenText))

        let loaded = await store.load(sessionID: snapshot.sessionID)
        let durable = try XCTUnwrap(loaded)
        XCTAssertEqual(durable.interviewerUtterances, [utterance])
    }

    func testLegacyManifestDecodesEmptyHistoryAndBackfillsWithoutSpeechEffects() async throws {
        let (_, store) = try await completedSession(id: "speech-legacy")
        let loaded = await store.load(sessionID: SessionID("speech-legacy"))
        let current = try XCTUnwrap(loaded)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
                as? [String: Any]
        )
        object.removeValue(forKey: "interviewerUtterances")
        let legacy = try JSONDecoder().decode(
            SessionManifest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(legacy.interviewerUtterances.isEmpty)

        let legacyStore = InMemorySessionManifestStore(manifests: [legacy])
        let restored = try await InterviewRoomSession.restore(
            sessionID: legacy.sessionID,
            manifestStore: legacyStore,
            interviewerRuntime: fixtureRuntime()
        )
        let application = try await restored.apply(
            .backfillInterviewerUtterances(
                commandID: CommandID("legacy-speech-backfill")
            )
        )
        XCTAssertEqual(application.disposition, .accepted)
        XCTAssertEqual(application.snapshot.interviewerUtterances.count, 1)
        XCTAssertEqual(application.snapshot.interviewerUtterances[0].lifecycle, .pending)
        XCTAssertTrue(application.snapshot.interviewerUtterances[0].synthesisAttempts.isEmpty)
    }

    func testAuthorizationIsDurableAndCommandReplayNeverCreatesAnotherAttempt() async throws {
        let (session, store) = try await completedSession(id: "speech-authorization")
        let initial = await session.snapshot()
        let utteranceID = try XCTUnwrap(initial.interviewerUtterances.first?.id)
        let command = InterviewRoomCommand.authorizeInterviewerSynthesis(
            commandID: CommandID("speech-authorize"),
            utteranceID: utteranceID,
            kind: .initial,
            provenance: fixtureProvenance()
        )

        let first = try await session.apply(command)
        let loaded = await store.load(sessionID: first.snapshot.sessionID)
        let durable = try XCTUnwrap(loaded)
        XCTAssertEqual(first.disposition, .accepted)
        XCTAssertEqual(durable.revision, first.snapshot.revision)
        XCTAssertEqual(durable.interviewerUtterances[0].lifecycle, .generating)
        XCTAssertEqual(durable.interviewerUtterances[0].synthesisAttempts.count, 1)
        XCTAssertEqual(
            durable.interviewerUtterances[0].synthesisAttempts[0].lifecycle,
            .authorized
        )

        let replay = try await session.apply(command)
        XCTAssertEqual(replay.disposition, .alreadyApplied)
        XCTAssertEqual(replay.snapshot.revision, first.snapshot.revision)
        XCTAssertEqual(replay.snapshot.interviewerUtterances[0].synthesisAttempts.count, 1)
    }

    func testSuccessfulAudioSelectionAndFailedRetryPreservePriorArtifact() async throws {
        let (session, _) = try await completedSession(id: "speech-retry-selection")
        let initial = await session.snapshot()
        let utteranceID = try XCTUnwrap(initial.interviewerUtterances.first?.id)
        let firstAuthorization = try await session.apply(
            .authorizeInterviewerSynthesis(
                commandID: CommandID("speech-first-attempt"),
                utteranceID: utteranceID,
                kind: .initial,
                provenance: fixtureProvenance()
            )
        )
        let firstAttempt = try XCTUnwrap(
            firstAuthorization.snapshot.interviewerUtterances[0].latestAttempt
        )
        _ = try await session.apply(
            .recordInterviewerSynthesisSpeaking(
                commandID: CommandID("speech-first-speaking"),
                utteranceID: utteranceID,
                attemptID: firstAttempt.id
            )
        )
        let firstAudio = validArtifact(identity: firstAttempt.finalAudioIdentity)
        let firstReady = try await session.apply(
            .recordInterviewerSynthesisOutcome(
                commandID: CommandID("speech-first-ready"),
                utteranceID: utteranceID,
                attemptID: firstAttempt.id,
                outcome: .ready(firstAudio)
            )
        )
        XCTAssertEqual(firstReady.snapshot.interviewerUtterances[0].selectedAudio, firstAudio)

        let retryAuthorization = try await session.apply(
            .authorizeInterviewerSynthesis(
                commandID: CommandID("speech-retry-attempt"),
                utteranceID: utteranceID,
                kind: .retry,
                provenance: fixtureProvenance()
            )
        )
        let retryAttempt = try XCTUnwrap(
            retryAuthorization.snapshot.interviewerUtterances[0].latestAttempt
        )
        XCTAssertNotEqual(retryAttempt.id, firstAttempt.id)
        let failedRetry = try await session.apply(
            .recordInterviewerSynthesisOutcome(
                commandID: CommandID("speech-retry-failed"),
                utteranceID: utteranceID,
                attemptID: retryAttempt.id,
                outcome: .failed(
                    InterviewerSynthesisFailure(reason: .providerFailed)
                )
            )
        )
        let utterance = failedRetry.snapshot.interviewerUtterances[0]
        XCTAssertEqual(utterance.lifecycle, .ready)
        XCTAssertEqual(utterance.selectedAttemptID, firstAttempt.id)
        XCTAssertEqual(utterance.selectedAudio, firstAudio)
        XCTAssertEqual(utterance.latestAttempt?.failure?.reason, .providerFailed)
    }

    func testRestoreRejectsSelectionOlderThanLatestReadyAttempt() async throws {
        let (session, store) = try await completedSession(id: "speech-stale-ready-selection")
        let initial = await session.snapshot()
        let utteranceID = try XCTUnwrap(initial.interviewerUtterances.first?.id)
        let firstAuthorization = try await session.apply(
            .authorizeInterviewerSynthesis(
                commandID: CommandID("stale-ready-first-authorize"),
                utteranceID: utteranceID,
                kind: .initial,
                provenance: fixtureProvenance()
            )
        )
        let firstAttempt = try XCTUnwrap(
            firstAuthorization.snapshot.interviewerUtterances[0].latestAttempt
        )
        _ = try await session.apply(
            .recordInterviewerSynthesisOutcome(
                commandID: CommandID("stale-ready-first-outcome"),
                utteranceID: utteranceID,
                attemptID: firstAttempt.id,
                outcome: .ready(validArtifact(identity: firstAttempt.finalAudioIdentity))
            )
        )
        let secondAuthorization = try await session.apply(
            .authorizeInterviewerSynthesis(
                commandID: CommandID("stale-ready-second-authorize"),
                utteranceID: utteranceID,
                kind: .retry,
                provenance: fixtureProvenance()
            )
        )
        let secondAttempt = try XCTUnwrap(
            secondAuthorization.snapshot.interviewerUtterances[0].latestAttempt
        )
        _ = try await session.apply(
            .recordInterviewerSynthesisOutcome(
                commandID: CommandID("stale-ready-second-outcome"),
                utteranceID: utteranceID,
                attemptID: secondAttempt.id,
                outcome: .ready(validArtifact(identity: secondAttempt.finalAudioIdentity))
            )
        )
        let persisted = await store.load(sessionID: initial.sessionID)
        let loaded = try XCTUnwrap(persisted)
        let current = try XCTUnwrap(loaded.interviewerUtterances.first)
        let staleSelection = InterviewerUtterance(
            id: current.id,
            turnID: current.turnID,
            spokenTextFingerprint: current.spokenTextFingerprint,
            lifecycle: .ready,
            synthesisAttempts: current.synthesisAttempts,
            selectedAttemptID: firstAttempt.id
        )

        await assertRestoreRejects(
            copying: loaded,
            interviewerUtterances: [staleSelection]
        )
    }

    func testSpeechFailureDoesNotChangeTurnOrInterviewProgress() async throws {
        let (session, _) = try await completedSession(id: "speech-nonblocking")
        let before = await session.snapshot()
        let utteranceID = try XCTUnwrap(before.interviewerUtterances.first?.id)
        let authorization = try await session.apply(
            .authorizeInterviewerSynthesis(
                commandID: CommandID("speech-nonblocking-authorize"),
                utteranceID: utteranceID,
                kind: .initial,
                provenance: fixtureProvenance()
            )
        )
        let attempt = try XCTUnwrap(
            authorization.snapshot.interviewerUtterances[0].latestAttempt
        )
        let failed = try await session.apply(
            .recordInterviewerSynthesisOutcome(
                commandID: CommandID("speech-nonblocking-failure"),
                utteranceID: utteranceID,
                attemptID: attempt.id,
                outcome: .failed(
                    InterviewerSynthesisFailure(reason: .modelUnavailable)
                )
            )
        )
        XCTAssertEqual(failed.snapshot.phase, .interviewerTurn)
        XCTAssertEqual(failed.snapshot.turns, before.turns)

        let floor = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("speech-nonblocking-floor"))
        )
        XCTAssertEqual(floor.phase, .candidateFloor)
        XCTAssertEqual(floor.turns, before.turns)
    }

    func testInvalidArtifactsAndProvenanceCannotBecomeDurable() async throws {
        let invalidProfileInputs: [() throws -> InterviewerSpeechProfile] = [
            {
                try InterviewerSpeechProfile(
                    profileID: "invalid-temperature",
                    language: "English",
                    conditioning: "Fixture",
                    maxTokens: 10,
                    temperature: .nan,
                    topP: 1,
                    topK: 0,
                    minP: 0,
                    repetitionPenalty: 1,
                    repetitionContextSize: 20,
                    streamingInterval: 0.32
                )
            },
            {
                try InterviewerSpeechProfile(
                    profileID: " invalid-id ",
                    language: "English",
                    conditioning: "Fixture",
                    maxTokens: 10,
                    temperature: 0.9,
                    topP: 1,
                    topK: 0,
                    minP: 0,
                    repetitionPenalty: 1,
                    repetitionContextSize: 20,
                    streamingInterval: 0.32
                )
            },
        ]
        for makeProfile in invalidProfileInputs {
            XCTAssertThrowsError(try makeProfile())
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                InterviewerAudioIdentity.self,
                from: Data(#""../speech.wav""#.utf8)
            )
        )

        let (session, _) = try await completedSession(id: "speech-invalid-outcomes")
        let initial = await session.snapshot()
        let utteranceID = try XCTUnwrap(initial.interviewerUtterances.first?.id)
        let badProvenance = InterviewerSpeechProvenance(
            providerID: "provider\nsecret",
            modelID: "fixture/model",
            modelRevision: "fixture-revision",
            profile: .maraV1
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await session.apply(
                .authorizeInterviewerSynthesis(
                    commandID: CommandID("speech-bad-provenance"),
                    utteranceID: utteranceID,
                    kind: .initial,
                    provenance: badProvenance
                )
            )
        }

        let authorization = try await session.apply(
            .authorizeInterviewerSynthesis(
                commandID: CommandID("speech-valid-for-bad-audio"),
                utteranceID: utteranceID,
                kind: .initial,
                provenance: fixtureProvenance()
            )
        )
        let attempt = try XCTUnwrap(
            authorization.snapshot.interviewerUtterances[0].latestAttempt
        )
        let invalidArtifacts = [
            InterviewerSpeechAudioArtifact(
                audioIdentity: attempt.finalAudioIdentity,
                sampleRate: 24_000,
                channelCount: 1,
                durationMilliseconds: 100_001,
                byteCount: 9_600_044,
                sha256: String(repeating: "a", count: 64)
            ),
            InterviewerSpeechAudioArtifact(
                audioIdentity: attempt.finalAudioIdentity,
                sampleRate: 24_000,
                channelCount: 1,
                durationMilliseconds: 1_000,
                byteCount: 96_045,
                sha256: String(repeating: "a", count: 64)
            ),
            InterviewerSpeechAudioArtifact(
                audioIdentity: attempt.finalAudioIdentity,
                sampleRate: 24_000,
                channelCount: 1,
                durationMilliseconds: 1_000,
                byteCount: 96_044,
                sha256: "not-a-sha256"
            ),
        ]
        for (index, artifact) in invalidArtifacts.enumerated() {
            await XCTAssertThrowsErrorAsync {
                _ = try await session.apply(
                    .recordInterviewerSynthesisOutcome(
                        commandID: CommandID("speech-invalid-audio-\(index)"),
                        utteranceID: utteranceID,
                        attemptID: attempt.id,
                        outcome: .ready(artifact)
                    )
                )
            }
        }
        let unchanged = await session.snapshot()
        XCTAssertEqual(unchanged.interviewerUtterances[0].latestAttempt?.lifecycle, .authorized)
    }

    func testRestoreRejectsMalformedAudioMetadataProfileAndIdentity() async throws {
        let (session, store) = try await completedSession(id: "speech-malformed-restore")
        let initial = await session.snapshot()
        let utteranceID = try XCTUnwrap(initial.interviewerUtterances.first?.id)
        _ = try await session.apply(
            .authorizeInterviewerSynthesis(
                commandID: CommandID("speech-malformed-authorize"),
                utteranceID: utteranceID,
                kind: .initial,
                provenance: fixtureProvenance()
            )
        )
        let loaded = await store.load(sessionID: initial.sessionID)
        let authorized = try XCTUnwrap(loaded)
        let validUtterance = try XCTUnwrap(authorized.interviewerUtterances.first)
        let validAttempt = try XCTUnwrap(validUtterance.latestAttempt)
        let malformedArtifacts = [
            InterviewerSpeechAudioArtifact(
                audioIdentity: validAttempt.finalAudioIdentity,
                sampleRate: 24_000,
                channelCount: 1,
                durationMilliseconds: 100_001,
                byteCount: 9_600_044,
                sha256: String(repeating: "a", count: 64)
            ),
            InterviewerSpeechAudioArtifact(
                audioIdentity: validAttempt.finalAudioIdentity,
                sampleRate: 24_000,
                channelCount: 1,
                durationMilliseconds: 1_000,
                byteCount: 96_045,
                sha256: String(repeating: "a", count: 64)
            ),
            InterviewerSpeechAudioArtifact(
                audioIdentity: validAttempt.finalAudioIdentity,
                sampleRate: 24_000,
                channelCount: 1,
                durationMilliseconds: 1_000,
                byteCount: 96_044,
                sha256: String(repeating: "G", count: 64)
            ),
        ]
        for artifact in malformedArtifacts {
            let malformedAttempt = SynthesisAttempt(
                id: validAttempt.id,
                authorizationCommandID: validAttempt.authorizationCommandID,
                kind: validAttempt.kind,
                provenance: validAttempt.provenance,
                partialAudioIdentity: validAttempt.partialAudioIdentity,
                finalAudioIdentity: validAttempt.finalAudioIdentity,
                lifecycle: .ready,
                audio: artifact
            )
            let malformedUtterance = InterviewerUtterance(
                id: validUtterance.id,
                turnID: validUtterance.turnID,
                spokenTextFingerprint: validUtterance.spokenTextFingerprint,
                lifecycle: .ready,
                synthesisAttempts: [malformedAttempt],
                selectedAttemptID: malformedAttempt.id
            )
            await assertRestoreRejects(
                copying: authorized,
                interviewerUtterances: [malformedUtterance]
            )
        }

        let encoded = try JSONEncoder().encode(authorized)
        var profileObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        try mutateFirstAttempt(in: &profileObject) { attempt in
            var provenance = try XCTUnwrap(attempt["provenance"] as? [String: Any])
            var profile = try XCTUnwrap(provenance["profile"] as? [String: Any])
            profile["fingerprint"] = "sha256:v1:\(String(repeating: "0", count: 64))"
            provenance["profile"] = profile
            attempt["provenance"] = provenance
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SessionManifest.self,
                from: JSONSerialization.data(withJSONObject: profileObject)
            )
        )

        var identityObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        try mutateFirstAttempt(in: &identityObject) { attempt in
            attempt["finalAudioIdentity"] = "../speech.wav"
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SessionManifest.self,
                from: JSONSerialization.data(withJSONObject: identityObject)
            )
        )
    }

    private func completedSession(
        id: String
    ) async throws -> (InterviewRoomSession, InMemorySessionManifestStore) {
        let store = InMemorySessionManifestStore()
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID(id),
            activityID: "activity-\(id)",
            activityPrompt: try ActivityPrompt(
                specialty: .systemDesign,
                stage: "High-level design",
                question: "Design a durable notification system.",
                requestedParts: ["Clarify requirements."]
            ),
            manifestStore: store,
            interviewerRuntime: fixtureRuntime()
        )
        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("floor-\(id)"))
        )
        _ = try await session.execute(
            .handOff(
                commandID: CommandID("handoff-\(id)"),
                transcript: CandidateTranscript(
                    body: "I would begin with the delivery guarantees.",
                    quality: .verified
                )
            )
        )
        return (session, store)
    }

    private func fixtureRuntime() -> DeterministicInterviewerRuntime {
        DeterministicInterviewerRuntime(
            response: CanonicalInterviewerResponse(
                displayMarkdown: "What consistency model would you choose?",
                spokenText: "What consistency model would you choose?"
            )
        )
    }

    private func fixtureProvenance() -> InterviewerSpeechProvenance {
        InterviewerSpeechProvenance(
            providerID: "local-qwen3-tts",
            modelID: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
            modelRevision: "049ef77fe8816b536193c0c25f9a214d17921282",
            profile: .maraV1
        )
    }

    private func validArtifact(
        identity: InterviewerAudioIdentity
    ) -> InterviewerSpeechAudioArtifact {
        InterviewerSpeechAudioArtifact(
            audioIdentity: identity,
            sampleRate: 24_000,
            channelCount: 1,
            durationMilliseconds: 1_000,
            byteCount: 96_044,
            sha256: String(repeating: "a", count: 64)
        )
    }

    private func assertRestoreRejects(
        copying manifest: SessionManifest,
        interviewerUtterances: [InterviewerUtterance],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let malformed = SessionManifest(
            sessionID: manifest.sessionID,
            activityID: manifest.activityID,
            activityPrompt: manifest.activityPrompt,
            phase: manifest.phase,
            turnMode: manifest.turnMode,
            turns: manifest.turns,
            segments: manifest.segments,
            endpointEvaluations: manifest.endpointEvaluations,
            interviewerUtterances: interviewerUtterances,
            revision: manifest.revision,
            appliedCommands: manifest.appliedCommands
        )
        do {
            _ = try await InterviewRoomSession.restore(
                sessionID: malformed.sessionID,
                manifestStore: InMemorySessionManifestStore(manifests: [malformed]),
                interviewerRuntime: fixtureRuntime()
            )
            XCTFail("Expected malformed speech Manifest rejection", file: file, line: line)
        } catch let error as InterviewRoomSessionError {
            guard case .invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected InterviewRoomSessionError, got \(error)", file: file, line: line)
        }
    }

    private func mutateFirstAttempt(
        in object: inout [String: Any],
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var utterances = try XCTUnwrap(
            object["interviewerUtterances"] as? [[String: Any]]
        )
        var attempts = try XCTUnwrap(
            utterances[0]["synthesisAttempts"] as? [[String: Any]]
        )
        try mutation(&attempts[0])
        utterances[0]["synthesisAttempts"] = attempts
        object["interviewerUtterances"] = utterances
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
