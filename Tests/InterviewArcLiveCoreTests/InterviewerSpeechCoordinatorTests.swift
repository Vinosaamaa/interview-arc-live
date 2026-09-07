import Foundation
import XCTest

@testable import InterviewArcLiveCore

@MainActor
final class InterviewerSpeechCoordinatorTests: XCTestCase {
    func testSwitchInvalidatesReplayWaitingForAudioValidation() async throws {
        let store = InMemorySessionManifestStore()
        let audio = SpeechAudioStoreFixture()
        let player = SpeechPlayerFixture()
        let provider = ScriptedSpeechProvider(readiness: .ready, events: validEvents(), manifestStore: store)
        let conversation = try await makeConversation(manifestStore: store)
        let speech = try await InterviewerSpeechCoordinator.attach(to: conversation,
            provider: provider, player: player, audioStore: audio)
        let turn = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(turn)
        await speech.waitUntilIdle()
        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        await audio.holdNextValidation()
        let replay = Task { @MainActor in try await speech.play(utteranceID: utterance.id) }
        await audio.waitForHeldValidation()
        let replacement = ScriptedSpeechProvider(readiness: .ready, events: validEvents(), manifestStore: store)
        _ = try await speech.replaceProvider(with: replacement, commandID: CommandID("switch-during-validation"))
        await audio.releaseValidation()
        do {
            try await replay.value
            XCTFail("The superseded replay must not start after the switch")
        } catch is CancellationError { }
        XCTAssertEqual(player.playCount, 0)
        XCTAssertEqual(speech.snapshot.interviewerUtterances.first, utterance)
    }

    func testOpeningSpeaksWhenAttachedBeforeRequestAndRestoreDoesNotReplayIt() async throws {
        let store = InMemorySessionManifestStore()
        let provider = ScriptedSpeechProvider(readiness: .ready, events: validEvents(), manifestStore: store)
        let conversation = try await makeConversation(manifestStore: store)
        let audio = SpeechAudioStoreFixture()
        let speech = try await InterviewerSpeechCoordinator.attach(to: conversation,
            provider: provider, player: SpeechPlayerFixture(), audioStore: audio)
        let opening = try await conversation.requestOpeningInterviewerTurn(commandID: CommandID("opening"))
        await speech.observeNewlyPersistedSnapshot(opening)
        await speech.waitUntilIdle()
        let spoken = await provider.synthesisCount()
        XCTAssertEqual(spoken, 1)
        XCTAssertNotNil(speech.snapshot.interviewerUtterances.first?.selectedAudio)
        let restored = try await InterviewerSpeechCoordinator.attach(to: conversation,
            provider: provider, player: SpeechPlayerFixture(), audioStore: audio)
        _ = try await restored.resumePendingWork()
        await restored.observeNewlyPersistedSnapshot(restored.snapshot)
        await restored.waitUntilIdle()
        let afterRestore = await provider.synthesisCount()
        XCTAssertEqual(afterRestore, 1)
    }

    func testEndingConversationJoinsSpeechAndCommitsStoppedAttemptBeforeCompletion() async throws {
        let store = InMemorySessionManifestStore()
        let provider = CancellationJoiningSpeechProvider(subsequentEvents: validEvents(), manifestStore: store)
        let conversation = try await makeConversation(manifestStore: store)
        let speech = try await InterviewerSpeechCoordinator.attach(to: conversation,
            provider: provider, player: SpeechPlayerFixture(), audioStore: SpeechAudioStoreFixture())
        let turn = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(turn)
        try await provider.waitUntilFirstProducerStarts()
        let completed = try await conversation.finishSession(commandID: CommandID("end-speaking"))
        let cancellations = await provider.cancellationCount()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.interviewerUtterances.first?.latestAttempt?.lifecycle, .stopped)
        XCTAssertEqual(completed.interviewerUtterances.first?.latestAttempt?.stopReason, .userStopped)
    }

    func testSwitchPreservesSavedAudioAndUsesReplacementOnlyForExplicitRetry() async throws {
        let store = InMemorySessionManifestStore()
        let original = ScriptedSpeechProvider(readiness: .ready, events: validEvents(), manifestStore: store)
        let replacementProvenance = InterviewerSpeechProvenance(
            providerID: "fixture-other-voice", modelID: "fixture/other-model",
            modelRevision: "0123456789abcdef0123456789abcdef01234567", profile: .maraV1)
        let replacement = ScriptedSpeechProvider(readiness: .ready, events: validEvents(),
            manifestStore: store, provenance: replacementProvenance)
        let conversation = try await makeConversation(manifestStore: store)
        let player = SpeechPlayerFixture()
        let speech = try await InterviewerSpeechCoordinator.attach(to: conversation,
            provider: original, player: player, audioStore: SpeechAudioStoreFixture())
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()
        let before = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)

        _ = try await speech.replaceProvider(with: replacement, commandID: CommandID("switch-voice"))
        XCTAssertEqual(speech.snapshot.interviewerUtterances.first, before)
        let callsBeforeRetry = await replacement.synthesisCount()
        XCTAssertEqual(callsBeforeRetry, 0)
        try await speech.play(utteranceID: before.id)
        XCTAssertEqual(player.playCount, 1)
        try await speech.retry(utteranceID: before.id, commandID: CommandID("new-voice-retry"))
        await speech.waitUntilIdle()

        let after = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(after.synthesisAttempts.count, 2)
        XCTAssertEqual(after.synthesisAttempts.first, before.synthesisAttempts.first)
        XCTAssertEqual(after.latestAttempt?.provenance, replacementProvenance)
        XCTAssertNotNil(after.selectedAudio)
    }

    func testSwitchDuringGenerationJoinsProducerAndRetainsStoppedAttempt() async throws {
        let store = InMemorySessionManifestStore()
        let original = CancellationJoiningSpeechProvider(subsequentEvents: validEvents(), manifestStore: store)
        let replacement = ScriptedSpeechProvider(readiness: .notInstalled, events: [], manifestStore: store)
        let conversation = try await makeConversation(manifestStore: store)
        let speech = try await InterviewerSpeechCoordinator.attach(to: conversation,
            provider: original, player: SpeechPlayerFixture(), audioStore: SpeechAudioStoreFixture())
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        try await original.waitUntilFirstProducerStarts()

        let readiness = try await speech.replaceProvider(with: replacement,
            commandID: CommandID("switch-while-speaking"))
        let cancellations = await original.cancellationCount()
        let replacementCalls = await replacement.synthesisCount()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(replacementCalls, 0)
        XCTAssertEqual(readiness, .notInstalled)
        XCTAssertEqual(speech.snapshot.interviewerUtterances.first?.latestAttempt?.lifecycle, .stopped)
        XCTAssertEqual(speech.snapshot.turns, completed.turns)
    }

    func testReadyNewTurnPersistsAuthorizationBeforeProviderAndStreamsToReadyAudio() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let audioStore = SpeechAudioStoreFixture()
        let player = SpeechPlayerFixture()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: player,
            audioStore: audioStore
        )

        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()

        let synthesisCount = await provider.synthesisCount()
        let prepareCount = await provider.prepareCount()
        let authorizationWasDurable = await provider.authorizationWasDurable()
        let beginCount = await audioStore.beginCount()
        let appendCount = await audioStore.appendCount()
        let finalizeCount = await audioStore.finalizeCount()
        XCTAssertEqual(synthesisCount, 1)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertTrue(authorizationWasDurable)
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(appendCount, 2)
        XCTAssertEqual(finalizeCount, 1)
        XCTAssertEqual(player.beginCount, 1)
        XCTAssertEqual(player.enqueueCount, 2)
        XCTAssertEqual(player.finishCount, 1)
        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.lifecycle, .ready)
        XCTAssertNotNil(utterance.selectedAudio)
        XCTAssertEqual(speech.snapshot.turns, completed.turns)
    }

    func testTransientAutomaticAuthorizationFailureRetriesWithoutDuplicateProviderEffect() async throws {
        let manifestStore = AuthorizationFailingStore()
        let audioStore = SpeechAudioStoreFixture()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: audioStore
        )
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await manifestStore.failNextAuthorizationOnce()

        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()

        let authorizationSaveCount = await manifestStore.authorizationSaveCount()
        let authorizationFailureCount = await manifestStore.authorizationFailureCount()
        let synthesisCount = await provider.synthesisCount()
        let prepareCount = await provider.prepareCount()
        let authorizationWasDurable = await provider.authorizationWasDurable()
        let beginCount = await audioStore.beginCount()
        XCTAssertEqual(authorizationSaveCount, 2)
        XCTAssertEqual(authorizationFailureCount, 1)
        XCTAssertEqual(synthesisCount, 1)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertTrue(authorizationWasDurable)
        XCTAssertEqual(beginCount, 1)
        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.synthesisAttempts.count, 1)
        XCTAssertEqual(utterance.lifecycle, .ready)
        XCTAssertNotNil(utterance.selectedAudio)
    }

    func testAttachRestoreAndUnavailableModelNeverSpeakHistoryOrDownload() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        let provider = ScriptedSpeechProvider(
            readiness: .notInstalled,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let audioStore = SpeechAudioStoreFixture()
        let player = SpeechPlayerFixture()
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: player,
            audioStore: audioStore
        )

        _ = try await speech.resumePendingWork()
        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()

        let synthesisCount = await provider.synthesisCount()
        let prepareCount = await provider.prepareCount()
        let beginCount = await audioStore.beginCount()
        XCTAssertEqual(synthesisCount, 0)
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(beginCount, 0)
        XCTAssertEqual(player.beginCount, 0)
        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].lifecycle, .pending)
    }

    func testInvalidPCMRecordsSafeFailureAndPreservesCanonicalTurn() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: [
                .pcm(
                    InterviewerSpeechPCMChunk(
                        samples: [0, .nan],
                        sampleRate: 24_000,
                        channelCount: 1
                    )
                ),
                .completed(
                    InterviewerSpeechGenerationMetrics(
                        chunkCount: 1,
                        generatedSampleCount: 2,
                        timeToFirstAudioMilliseconds: 1,
                        totalGenerationMilliseconds: 2
                    )
                ),
            ],
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: SpeechAudioStoreFixture()
        )
        let completed = try await completeTurn(in: conversation.interviewRoomSession)

        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()

        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.lifecycle, .failed)
        XCTAssertEqual(utterance.latestAttempt?.failure?.reason, .invalidAudio)
        XCTAssertEqual(speech.snapshot.turns, completed.turns)
        XCTAssertEqual(speech.snapshot.phase, .interviewerTurn)
    }

    func testNewTurnQueuedWhilePriorSpeechIsActiveStartsAfterPriorAttemptCompletes() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let audioStore = SpeechAudioStoreFixture(holdAppend: true)
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: audioStore
        )

        let first = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(first)
        await audioStore.waitUntilAppendStarted()
        _ = try await conversation.interviewRoomSession.execute(
            .giveCandidateFloor(commandID: CommandID("queued-turn-floor"))
        )
        let second = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(second)

        await audioStore.releaseAppend()
        await speech.waitUntilIdle()

        let synthesisCount = await provider.synthesisCount()
        let beginCount = await audioStore.beginCount()
        let finalizeCount = await audioStore.finalizeCount()
        XCTAssertEqual(synthesisCount, 2)
        XCTAssertEqual(beginCount, 2)
        XCTAssertEqual(finalizeCount, 2)
        XCTAssertEqual(speech.snapshot.interviewerUtterances.count, 2)
        XCTAssertTrue(speech.snapshot.interviewerUtterances.allSatisfy {
            $0.lifecycle == .ready && $0.selectedAudio != nil
        })
    }

    func testSlowGenerationMetricsDoNotInvalidateBoundedAudio() async throws {
        let manifestStore = InMemorySessionManifestStore()
        var events = validEvents()
        events[2] = .completed(
            InterviewerSpeechGenerationMetrics(
                chunkCount: 2,
                generatedSampleCount: 24_000,
                timeToFirstAudioMilliseconds: 125_000,
                totalGenerationMilliseconds: 300_000
            )
        )
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: events,
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: SpeechAudioStoreFixture()
        )

        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()

        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].lifecycle, .ready)
        XCTAssertEqual(speech.lastGenerationMetrics?.totalGenerationMilliseconds, 300_000)
    }

    func testActiveGenerateCommandReplayIsZeroEffect() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let conversation = try await makeConversation(manifestStore: manifestStore)
        _ = try await completeTurn(in: conversation.interviewRoomSession)
        let audioStore = SpeechAudioStoreFixture(holdAppend: true)
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: audioStore
        )
        let utteranceID = try XCTUnwrap(speech.snapshot.interviewerUtterances.first?.id)
        let commandID = CommandID("active-generate-replay")

        try await speech.retry(utteranceID: utteranceID, commandID: commandID)
        await audioStore.waitUntilAppendStarted()
        try await speech.retry(utteranceID: utteranceID, commandID: commandID)
        await audioStore.releaseAppend()
        await speech.waitUntilIdle()

        let synthesisCount = await provider.synthesisCount()
        XCTAssertEqual(synthesisCount, 1)
        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].synthesisAttempts.count, 1)
        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].lifecycle, .ready)
    }

    func testTerminalGenerateCommandReplayIsZeroEffectBeforeMuteGuard() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let conversation = try await makeConversation(manifestStore: manifestStore)
        _ = try await completeTurn(in: conversation.interviewRoomSession)
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: SpeechAudioStoreFixture()
        )
        let utteranceID = try XCTUnwrap(speech.snapshot.interviewerUtterances.first?.id)
        let commandID = CommandID("terminal-generate-replay")
        try await speech.retry(utteranceID: utteranceID, commandID: commandID)
        await speech.waitUntilIdle()
        try await speech.setMuted(true, commandID: CommandID("mute-after-terminal"))

        try await speech.retry(utteranceID: utteranceID, commandID: commandID)

        let synthesisCount = await provider.synthesisCount()
        XCTAssertEqual(synthesisCount, 1)
        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].synthesisAttempts.count, 1)
        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].lifecycle, .ready)
    }

    func testStoppingActiveTurnAllowsQueuedNewTurnToStart() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let audioStore = SpeechAudioStoreFixture(holdAppend: true)
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: audioStore
        )
        let first = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(first)
        await audioStore.waitUntilAppendStarted()
        _ = try await conversation.interviewRoomSession.execute(
            .giveCandidateFloor(commandID: CommandID("queued-after-stop-floor"))
        )
        let second = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(second)

        let stopTask = Task { @MainActor in
            try await speech.stop(commandID: CommandID("stop-before-queued-turn"))
        }
        await Task.yield()
        await audioStore.releaseAppend()
        try await stopTask.value
        await speech.waitUntilIdle()

        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].lifecycle, .stopped)
        XCTAssertEqual(speech.snapshot.interviewerUtterances[1].lifecycle, .ready)
        let synthesisCount = await provider.synthesisCount()
        XCTAssertEqual(synthesisCount, 2)
    }

    func testStopDuringBlockedAppendSerializesCancellationBeforeStoppedOutcome() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let audioStore = SpeechAudioStoreFixture(holdAppend: true)
        let player = SpeechPlayerFixture()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: player,
            audioStore: audioStore
        )
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await audioStore.waitUntilAppendStarted()

        let stopTask = Task { @MainActor in
            try await speech.stop(commandID: CommandID("stop-blocked-append"))
        }
        await Task.yield()
        await audioStore.releaseAppend()
        try await stopTask.value
        await speech.waitUntilIdle()

        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.lifecycle, .stopped)
        XCTAssertEqual(utterance.latestAttempt?.lifecycle, .stopped)
        XCTAssertEqual(utterance.latestAttempt?.stopReason, .userStopped)
        XCTAssertGreaterThanOrEqual(player.stopCount, 1)
        let discardCount = await audioStore.discardCount()
        let finalizeCount = await audioStore.finalizeCount()
        XCTAssertEqual(discardCount, 1)
        XCTAssertEqual(finalizeCount, 0)
    }

    func testConcurrentStopsJoinOneCancellationFinalizer() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let audioStore = SpeechAudioStoreFixture(holdAppend: true)
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: ScriptedSpeechProvider(
                readiness: .ready,
                events: validEvents(),
                manifestStore: manifestStore
            ),
            player: SpeechPlayerFixture(),
            audioStore: audioStore
        )
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await audioStore.waitUntilAppendStarted()

        let first = Task { @MainActor in
            try await speech.stop(commandID: CommandID("joined-stop-first"))
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await speech.stop(commandID: CommandID("joined-stop-second"))
        }
        await Task.yield()
        await audioStore.releaseAppend()
        try await first.value
        try await second.value

        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.lifecycle, .stopped)
        XCTAssertEqual(utterance.latestAttempt?.stopReason, .userStopped)
        let discardCount = await audioStore.discardCount()
        XCTAssertEqual(discardCount, 1)
    }

    func testConcurrentStopAndMuteJoinOneCancellationFinalizer() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let audioStore = SpeechAudioStoreFixture(holdAppend: true)
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: ScriptedSpeechProvider(
                readiness: .ready,
                events: validEvents(),
                manifestStore: manifestStore
            ),
            player: SpeechPlayerFixture(),
            audioStore: audioStore
        )
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await audioStore.waitUntilAppendStarted()

        let stop = Task { @MainActor in
            try await speech.stop(commandID: CommandID("joined-stop-before-mute"))
        }
        await Task.yield()
        let mute = Task { @MainActor in
            try await speech.setMuted(true, commandID: CommandID("joined-mute-after-stop"))
        }
        await Task.yield()
        await audioStore.releaseAppend()
        try await stop.value
        try await mute.value

        XCTAssertTrue(speech.isMuted)
        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.lifecycle, .stopped)
        XCTAssertEqual(utterance.latestAttempt?.stopReason, .userStopped)
        let discardCount = await audioStore.discardCount()
        XCTAssertEqual(discardCount, 1)
    }

    func testImmediateRetryAfterStopWaitsForProviderProducerCancellation() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let conversation = try await makeConversation(manifestStore: manifestStore)
        _ = try await completeTurn(in: conversation.interviewRoomSession)
        let provider = CancellationJoiningSpeechProvider(
            subsequentEvents: validEvents(),
            manifestStore: manifestStore
        )
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: SpeechAudioStoreFixture()
        )
        let utteranceID = try XCTUnwrap(speech.snapshot.interviewerUtterances.first?.id)
        try await speech.retry(
            utteranceID: utteranceID,
            commandID: CommandID("cancel-producer-first")
        )
        try await provider.waitUntilFirstProducerStarts()

        try await speech.stop(commandID: CommandID("cancel-producer-stop"))
        try await speech.retry(
            utteranceID: utteranceID,
            commandID: CommandID("cancel-producer-retry")
        )
        await speech.waitUntilIdle()

        let synthesisCount = await provider.synthesisCount()
        let cancellationCount = await provider.cancellationCount()
        XCTAssertEqual(synthesisCount, 2)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].lifecycle, .ready)
        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].synthesisAttempts.count, 2)
    }

    func testStopDuringBlockedFinalizeCannotPublishCompetingReadyOutcome() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let audioStore = SpeechAudioStoreFixture(holdFinalize: true)
        let player = SpeechPlayerFixture()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: player,
            audioStore: audioStore
        )
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await audioStore.waitUntilFinalizeStarted()

        let stopTask = Task { @MainActor in
            try await speech.stop(commandID: CommandID("stop-blocked-finalize"))
        }
        await provider.waitUntilCancellationRequested()
        await audioStore.releaseFinalize()
        try await stopTask.value

        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.lifecycle, .stopped)
        XCTAssertEqual(utterance.latestAttempt?.lifecycle, .stopped)
        XCTAssertNil(utterance.selectedAudio)
        let finalizeCount = await audioStore.finalizeCount()
        XCTAssertEqual(finalizeCount, 1)
    }

    func testMuteStopsSavedPlaybackWithoutProviderReplay() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let audioStore = SpeechAudioStoreFixture()
        let player = SpeechPlayerFixture()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: player,
            audioStore: audioStore
        )
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()
        let utteranceID = try XCTUnwrap(speech.snapshot.interviewerUtterances.first?.id)
        player.holdSavedPlayback = true

        let playTask = Task { @MainActor in try await speech.play(utteranceID: utteranceID) }
        await player.waitUntilSavedPlaybackStarts()
        try await speech.setMuted(true, commandID: CommandID("mute-saved-playback"))
        try await playTask.value

        XCTAssertTrue(speech.isMuted)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertGreaterThanOrEqual(player.stopCount, 1)
        let synthesisCount = await provider.synthesisCount()
        XCTAssertEqual(synthesisCount, 1)
    }

    func testFinalRenameThenManifestFailureRemainsRecoverableWithoutProviderReplay() async throws {
        let manifestStore = ReadyOutcomeFailingStore()
        let audioStore = SpeechAudioStoreFixture()
        let player = SpeechPlayerFixture()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: player,
            audioStore: audioStore
        )
        await manifestStore.setFailsReadyOutcome(true)
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()

        let finalizeCount = await audioStore.finalizeCount()
        let synthesisCountBeforeRecovery = await provider.synthesisCount()
        XCTAssertEqual(finalizeCount, 1)
        XCTAssertEqual(synthesisCountBeforeRecovery, 1)
        let interrupted = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertTrue(
            interrupted.latestAttempt?.lifecycle == .authorized
                || interrupted.latestAttempt?.lifecycle == .speaking
        )
        XCTAssertNil(interrupted.latestAttempt?.failure)

        await manifestStore.setFailsReadyOutcome(false)
        _ = try await speech.resumePendingWork()

        let recovered = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(recovered.lifecycle, .ready)
        XCTAssertNotNil(recovered.selectedAudio)
        let synthesisCountAfterRecovery = await provider.synthesisCount()
        XCTAssertEqual(synthesisCountAfterRecovery, 1)
        XCTAssertEqual(player.enqueueCount, 2)
    }

    func testTransientReadySaveFailureReconcilesArtifactWithoutSecondGeneration() async throws {
        let manifestStore = ReadyOutcomeFailingStore()
        let audioStore = SpeechAudioStoreFixture()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: SpeechPlayerFixture(),
            audioStore: audioStore
        )
        await manifestStore.failNextReadyOutcomeOnce()
        let completed = try await completeTurn(in: conversation.interviewRoomSession)

        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()

        XCTAssertEqual(speech.snapshot.interviewerUtterances[0].lifecycle, .ready)
        XCTAssertNotNil(speech.snapshot.interviewerUtterances[0].selectedAudio)
        let synthesisCount = await provider.synthesisCount()
        let finalizeCount = await audioStore.finalizeCount()
        let readyFailureCount = await manifestStore.readyFailureCount()
        XCTAssertEqual(synthesisCount, 1)
        XCTAssertEqual(finalizeCount, 1)
        XCTAssertEqual(readyFailureCount, 1)
    }

    func testStopDuringReadyPersistenceHonorsTheDurableCommitThatWins() async throws {
        let manifestStore = ReadyOutcomeFailingStore()
        let audioStore = SpeechAudioStoreFixture()
        let player = SpeechPlayerFixture()
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: player,
            audioStore: audioStore
        )
        await manifestStore.setHoldsReadyOutcome(true)
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        await speech.observeNewlyPersistedSnapshot(completed)
        await manifestStore.waitUntilReadySaveStarts()

        let stopTask = Task { @MainActor in
            try await speech.stop(commandID: CommandID("stop-during-ready-save"))
        }
        await Task.yield()
        await manifestStore.releaseReadySave()
        try await stopTask.value

        let utterance = try XCTUnwrap(speech.snapshot.interviewerUtterances.first)
        XCTAssertEqual(utterance.lifecycle, .ready)
        XCTAssertNotNil(utterance.selectedAudio)
        XCTAssertNil(utterance.latestAttempt?.failure)
        XCTAssertGreaterThanOrEqual(player.stopCount, 1)
        let synthesisCount = await provider.synthesisCount()
        XCTAssertEqual(synthesisCount, 1)
    }

    func testPartialOnlyRecoveryMarksInterruptedWithoutProviderOrPlayback() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let conversation = try await makeConversation(manifestStore: manifestStore)
        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        let utteranceID = try XCTUnwrap(completed.interviewerUtterances.first?.id)
        _ = try await conversation.interviewRoomSession.apply(
            .authorizeInterviewerSynthesis(
                commandID: CommandID("partial-recovery-authorize"),
                utteranceID: utteranceID,
                kind: .initial,
                provenance: fixtureProvenance()
            )
        )
        let provider = ScriptedSpeechProvider(
            readiness: .ready,
            events: validEvents(),
            manifestStore: manifestStore
        )
        let audioStore = SpeechAudioStoreFixture(recoveryReturnsFinal: false)
        let player = SpeechPlayerFixture()
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: provider,
            player: player,
            audioStore: audioStore
        )

        _ = try await speech.resumePendingWork()

        let synthesisCount = await provider.synthesisCount()
        XCTAssertEqual(synthesisCount, 0)
        XCTAssertEqual(player.beginCount, 0)
        let discardCount = await audioStore.discardCount()
        XCTAssertEqual(discardCount, 1)
        XCTAssertEqual(
            speech.snapshot.interviewerUtterances[0].latestAttempt?.failure?.reason,
            .interrupted
        )
    }

    func testAutomaticPlaybackCompletionGivesCandidateFloorWhenListening() async throws {
        let manifestStore = InMemorySessionManifestStore()
        let conversation = try await makeConversation(manifestStore: manifestStore)
        await conversation.enableContinuousListening()
        _ = try await conversation.giveCandidateFloor(
            commandID: CommandID("listening-floor")
        )
        let speech = try await InterviewerSpeechCoordinator.attach(
            to: conversation,
            provider: ScriptedSpeechProvider(
                readiness: .ready,
                events: validEvents(),
                manifestStore: manifestStore
            ),
            player: SpeechPlayerFixture(),
            audioStore: SpeechAudioStoreFixture()
        )

        let completed = try await completeTurn(in: conversation.interviewRoomSession)
        _ = try await conversation.resumePendingWork()
        await speech.observeNewlyPersistedSnapshot(completed)
        await speech.waitUntilIdle()

        XCTAssertEqual(conversation.snapshot.phase, .candidateFloor)
        XCTAssertEqual(speech.snapshot.interviewerUtterances.first?.lifecycle, .ready)
    }

    private func makeConversation(
        manifestStore: any SessionManifestStore
    ) async throws -> SegmentSpeechCoordinator {
        try await SegmentSpeechCoordinator.open(
            sessionID: SessionID("speech-coordinator-\(UUID().uuidString)"),
            activityID: "speech-coordinator-fixture",
            activityPrompt: try ActivityPrompt(
                specialty: .systemDesign,
                stage: "High-level design",
                question: "Design a global notification system.",
                requestedParts: ["Clarify requirements."]
            ),
            manifestStore: manifestStore,
            interviewerRuntime: DeterministicInterviewerRuntime(
                response: CanonicalInterviewerResponse(
                    displayMarkdown: "Let's clarify the requirements.",
                    spokenText: "Let's clarify the requirements."
                )
            ),
            recording: UnusedSpeechRecording(),
            transcriber: UnusedSpeechTranscriber(),
            credentialReader: UnusedSpeechCredentialReader()
        )
    }

    private func completeTurn(
        in session: InterviewRoomSession
    ) async throws -> InterviewRoomSnapshot {
        let current = await session.snapshot()
        if current.phase == .ready {
            _ = try await session.execute(
                .giveCandidateFloor(commandID: CommandID("speech-floor-\(UUID().uuidString)"))
            )
        }
        return try await session.execute(
            .handOff(
                commandID: CommandID("speech-handoff-\(UUID().uuidString)"),
                transcript: CandidateTranscript(
                    body: "I would start by defining delivery semantics.",
                    quality: .verified
                )
            )
        )
    }

    private func validEvents() -> [InterviewerSpeechEvent] {
        let first = InterviewerSpeechPCMChunk(
            samples: Array(repeating: 0.1, count: 12_000),
            sampleRate: 24_000,
            channelCount: 1
        )
        let second = InterviewerSpeechPCMChunk(
            samples: Array(repeating: -0.1, count: 12_000),
            sampleRate: 24_000,
            channelCount: 1
        )
        return [
            .pcm(first),
            .pcm(second),
            .completed(
                InterviewerSpeechGenerationMetrics(
                    chunkCount: 2,
                    generatedSampleCount: 24_000,
                    timeToFirstAudioMilliseconds: 10,
                    totalGenerationMilliseconds: 100
                )
            ),
        ]
    }
}

private func fixtureProvenance() -> InterviewerSpeechProvenance {
    InterviewerSpeechProvenance(
        providerID: "local-qwen3-tts",
        modelID: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
        modelRevision: "049ef77fe8816b536193c0c25f9a214d17921282",
        profile: .maraV1
    )
}

private actor ScriptedSpeechProvider: InterviewerSpeechProvider {
    nonisolated let provenance: InterviewerSpeechProvenance
    private let readinessValue: InterviewerSpeechReadiness
    private let events: [InterviewerSpeechEvent]
    private let manifestStore: (any SessionManifestStore)?
    private var synthesisCalls = 0
    private var preparationCalls = 0
    private var cancellationRequests = 0
    private var cancellationStartedContinuation: CheckedContinuation<Void, Never>?
    private var observedDurableAuthorization = false

    init(
        readiness: InterviewerSpeechReadiness,
        events: [InterviewerSpeechEvent],
        manifestStore: (any SessionManifestStore)?,
        provenance: InterviewerSpeechProvenance = fixtureProvenance()
    ) {
        self.provenance = provenance
        readinessValue = readiness
        self.events = events
        self.manifestStore = manifestStore
    }

    func readiness() -> InterviewerSpeechReadiness { readinessValue }

    func prepare(
        _ policy: InterviewerSpeechPreparationPolicy,
        progress: @escaping @Sendable (InterviewerSpeechPreparationProgress) -> Void
    ) -> InterviewerSpeechReadiness {
        preparationCalls += 1
        return readinessValue
    }

    func synthesize(
        _ request: InterviewerSpeechSynthesisRequest
    ) async throws -> AsyncThrowingStream<InterviewerSpeechEvent, Error> {
        synthesisCalls += 1
        if let manifest = try await manifestStore?.load(sessionID: request.sessionID),
           manifest.interviewerUtterances.contains(where: { utterance in
               utterance.synthesisAttempts.contains(where: {
                   $0.id == request.attemptID
                       && ($0.lifecycle == .authorized || $0.lifecycle == .speaking)
               })
           }) {
            observedDurableAuthorization = true
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func unload() {}
    func cancelSynthesis() {
        cancellationRequests += 1
        cancellationStartedContinuation?.resume()
        cancellationStartedContinuation = nil
    }
    func removePreparedModel() -> InterviewerSpeechReadiness { .notInstalled }
    func synthesisCount() -> Int { synthesisCalls }
    func prepareCount() -> Int { preparationCalls }
    func authorizationWasDurable() -> Bool { observedDurableAuthorization }

    func waitUntilCancellationRequested() async {
        if cancellationRequests > 0 { return }
        await withCheckedContinuation { continuation in
            cancellationStartedContinuation = continuation
        }
    }
}

private actor CancellationJoiningSpeechProvider: InterviewerSpeechProvider {
    nonisolated let provenance = fixtureProvenance()
    private let subsequentEvents: [InterviewerSpeechEvent]
    private let manifestStore: any SessionManifestStore
    private var calls = 0
    private var cancellations = 0
    private var firstProducer: Task<Void, Never>?
    private var firstProducerStarted = false
    private let firstProducerStartedEvents: AsyncStream<Void>
    private let firstProducerStartedContinuation: AsyncStream<Void>.Continuation

    init(
        subsequentEvents: [InterviewerSpeechEvent],
        manifestStore: any SessionManifestStore
    ) {
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.subsequentEvents = subsequentEvents
        self.manifestStore = manifestStore
        firstProducerStartedEvents = events
        firstProducerStartedContinuation = continuation
    }

    func readiness() -> InterviewerSpeechReadiness { .ready }

    func prepare(
        _ policy: InterviewerSpeechPreparationPolicy,
        progress: @escaping @Sendable (InterviewerSpeechPreparationProgress) -> Void
    ) -> InterviewerSpeechReadiness {
        .ready
    }

    func synthesize(
        _ request: InterviewerSpeechSynthesisRequest
    ) async throws -> AsyncThrowingStream<InterviewerSpeechEvent, Error> {
        guard let manifest = try await manifestStore.load(sessionID: request.sessionID),
              manifest.interviewerUtterances.contains(where: { utterance in
                  utterance.synthesisAttempts.contains(where: { $0.id == request.attemptID })
              }) else {
            throw SpeechFixtureError.manifestWriteFailed
        }
        calls += 1
        if calls > 1 {
            return AsyncThrowingStream { continuation in
                for event in subsequentEvents { continuation.yield(event) }
                continuation.finish()
            }
        }
        let (stream, continuation) = AsyncThrowingStream<InterviewerSpeechEvent, Error>
            .makeStream()
        let producer = Task { [weak self] in
            await self?.markFirstProducerStarted()
            do {
                while true { try await Task.sleep(for: .seconds(10)) }
            } catch {
                continuation.finish(throwing: CancellationError())
            }
        }
        continuation.onTermination = { @Sendable _ in producer.cancel() }
        firstProducer = producer
        return stream
    }

    func cancelSynthesis() async {
        guard let producer = firstProducer else { return }
        cancellations += 1
        producer.cancel()
        await producer.value
        firstProducer = nil
    }

    func unload() async { await cancelSynthesis() }
    func removePreparedModel() -> InterviewerSpeechReadiness { .notInstalled }
    func synthesisCount() -> Int { calls }
    func cancellationCount() -> Int { cancellations }

    func waitUntilFirstProducerStarts() async throws {
        if firstProducerStarted { return }
        let events = firstProducerStartedEvents
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                var iterator = events.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    throw SpeechFixtureError.producerDidNotStart
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw SpeechFixtureError.producerDidNotStart
            }
            _ = try await group.next()
        }
    }

    private func markFirstProducerStarted() {
        guard !firstProducerStarted else { return }
        firstProducerStarted = true
        firstProducerStartedContinuation.yield(())
        firstProducerStartedContinuation.finish()
    }
}

private actor SpeechAudioStoreFixture: InterviewerSpeechAudioStoring {
    private let holdAppend: Bool
    private let holdFinalize: Bool
    private let recoveryReturnsFinal: Bool
    private var requests: [SynthesisAttemptID: InterviewerSpeechAudioWriteRequest] = [:]
    private var sampleCounts: [SynthesisAttemptID: Int] = [:]
    private var finalized: [SynthesisAttemptID: InterviewerSpeechAudioArtifact] = [:]
    private var appendStartedContinuation: CheckedContinuation<Void, Never>?
    private var appendReleaseContinuation: CheckedContinuation<Void, Never>?
    private var finalizeStartedContinuation: CheckedContinuation<Void, Never>?
    private var finalizeReleaseContinuation: CheckedContinuation<Void, Never>?
    private var begins = 0
    private var appends = 0
    private var finalizes = 0
    private var discards = 0
    private var holdsNextValidation = false
    private var validationIsHeld = false
    private var validationStarted: CheckedContinuation<Void, Never>?
    private var validationRelease: CheckedContinuation<Void, Never>?

    init(
        holdAppend: Bool = false,
        holdFinalize: Bool = false,
        recoveryReturnsFinal: Bool = true
    ) {
        self.holdAppend = holdAppend
        self.holdFinalize = holdFinalize
        self.recoveryReturnsFinal = recoveryReturnsFinal
    }

    func beginWrite(_ request: InterviewerSpeechAudioWriteRequest) {
        begins += 1
        requests[request.attemptID] = request
        sampleCounts[request.attemptID] = 0
    }

    func append(_ chunk: InterviewerSpeechPCMChunk, attemptID: SynthesisAttemptID) async {
        appends += 1
        sampleCounts[attemptID, default: 0] += chunk.samples.count
        if holdAppend, appends == 1 {
            appendStartedContinuation?.resume()
            appendStartedContinuation = nil
            await withCheckedContinuation { continuation in
                appendReleaseContinuation = continuation
            }
        }
    }

    func finalizeWrite(
        attemptID: SynthesisAttemptID
    ) async throws -> InterviewerSpeechAudioArtifact {
        finalizes += 1
        if holdFinalize {
            finalizeStartedContinuation?.resume()
            finalizeStartedContinuation = nil
            await withCheckedContinuation { continuation in
                finalizeReleaseContinuation = continuation
            }
        }
        guard let request = requests[attemptID] else {
            throw SpeechFixtureError.missingWrite
        }
        let samples = sampleCounts[attemptID, default: 0]
        let artifact = InterviewerSpeechAudioArtifact(
            audioIdentity: request.finalAudioIdentity,
            sampleRate: 24_000,
            channelCount: 1,
            durationMilliseconds: Int64(samples * 1_000 / 24_000),
            byteCount: Int64(44 + samples * 4),
            sha256: String(repeating: "b", count: 64)
        )
        finalized[attemptID] = artifact
        return artifact
    }

    func discardPartial(attemptID: SynthesisAttemptID) { discards += 1 }

    func recoverFinalizedAudio(
        _ request: InterviewerSpeechAudioRecoveryRequest
    ) -> InterviewerSpeechAudioArtifact? {
        guard recoveryReturnsFinal else { return nil }
        return finalized[request.attemptID]
    }

    func validateAudio(
        sessionID: SessionID,
        artifact: InterviewerSpeechAudioArtifact
    ) async -> Bool {
        if holdsNextValidation {
            holdsNextValidation = false
            validationIsHeld = true
            validationStarted?.resume()
            validationStarted = nil
            await withCheckedContinuation { validationRelease = $0 }
        }
        return finalized.values.contains(artifact)
    }

    func holdNextValidation() { holdsNextValidation = true }
    func waitForHeldValidation() async {
        if validationIsHeld { return }
        await withCheckedContinuation { validationStarted = $0 }
    }
    func releaseValidation() {
        validationRelease?.resume()
        validationRelease = nil
        validationIsHeld = false
    }

    func waitUntilAppendStarted() async {
        if appends > 0 { return }
        await withCheckedContinuation { continuation in
            appendStartedContinuation = continuation
        }
    }

    func releaseAppend() {
        appendReleaseContinuation?.resume()
        appendReleaseContinuation = nil
    }

    func waitUntilFinalizeStarted() async {
        if finalizes > 0 { return }
        await withCheckedContinuation { continuation in
            finalizeStartedContinuation = continuation
        }
    }

    func releaseFinalize() {
        finalizeReleaseContinuation?.resume()
        finalizeReleaseContinuation = nil
    }

    func beginCount() -> Int { begins }
    func appendCount() -> Int { appends }
    func finalizeCount() -> Int { finalizes }
    func discardCount() -> Int { discards }
}

@MainActor
private final class SpeechPlayerFixture: InterviewerSpeechPlaying {
    var beginCount = 0
    var enqueueCount = 0
    var finishCount = 0
    var stopCount = 0
    var playCount = 0
    var holdSavedPlayback = false
    private var playbackStartContinuation: CheckedContinuation<Void, Never>?
    private var playbackStopContinuation: CheckedContinuation<Void, Never>?

    func beginStreaming(sampleRate: Int, channelCount: Int) { beginCount += 1 }
    func enqueue(_ chunk: InterviewerSpeechPCMChunk) { enqueueCount += 1 }
    func finishStreaming() { finishCount += 1 }

    func stop() {
        stopCount += 1
        playbackStopContinuation?.resume()
        playbackStopContinuation = nil
    }

    func play(_ request: InterviewerSpeechPlaybackRequest) async {
        playCount += 1
        playbackStartContinuation?.resume()
        playbackStartContinuation = nil
        if holdSavedPlayback {
            await withCheckedContinuation { continuation in
                playbackStopContinuation = continuation
            }
        }
    }

    func waitUntilSavedPlaybackStarts() async {
        if playCount > 0 { return }
        await withCheckedContinuation { continuation in
            playbackStartContinuation = continuation
        }
    }
}

@MainActor
private final class UnusedSpeechRecording: SegmentRecording {
    func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {}
    func beginCapture(_ request: SegmentCaptureRequest) async throws {
        throw SpeechFixtureError.unused
    }
    func finishCapture() async throws -> CapturedAudioSegment {
        throw SpeechFixtureError.unused
    }
    func recoverCapture(_ request: SegmentCaptureRequest) async throws -> CapturedAudioSegment? {
        nil
    }
    func playbackURL(
        sessionID: SessionID,
        audioIdentity: SegmentAudioIdentity
    ) async throws -> URL {
        throw SpeechFixtureError.unused
    }
}

private struct UnusedSpeechTranscriber: SegmentTranscribing {
    func transcribe(
        _ request: SegmentTranscriptionRequest,
        credential: String
    ) async throws -> SegmentTranscriptionResult {
        throw SpeechFixtureError.unused
    }
}

private struct UnusedSpeechCredentialReader: GroqCredentialReading {
    func readGroqCredential() async throws -> String { "unused" }
}

private actor ReadyOutcomeFailingStore: SessionManifestStore {
    private let backing = InMemorySessionManifestStore()
    private var failsReadyOutcome = false
    private var readyFailuresRemaining = 0
    private var observedReadyFailures = 0
    private var holdsReadyOutcome = false
    private var readySaveStartedContinuation: CheckedContinuation<Void, Never>?
    private var readySaveReleaseContinuation: CheckedContinuation<Void, Never>?

    func setFailsReadyOutcome(_ value: Bool) { failsReadyOutcome = value }
    func failNextReadyOutcomeOnce() { readyFailuresRemaining = 1 }
    func readyFailureCount() -> Int { observedReadyFailures }
    func setHoldsReadyOutcome(_ value: Bool) { holdsReadyOutcome = value }

    func waitUntilReadySaveStarts() async {
        if readySaveReleaseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            readySaveStartedContinuation = continuation
        }
    }

    func releaseReadySave() {
        readySaveReleaseContinuation?.resume()
        readySaveReleaseContinuation = nil
        holdsReadyOutcome = false
    }

    func load(sessionID: SessionID) async throws -> SessionManifest? {
        await backing.load(sessionID: sessionID)
    }

    func save(_ manifest: SessionManifest, expectedRevision: Int?) async throws {
        let storesReadyOutcome = manifest.interviewerUtterances.contains(where: {
            $0.synthesisAttempts.last?.lifecycle == .ready
        })
        if storesReadyOutcome && holdsReadyOutcome {
            readySaveStartedContinuation?.resume()
            readySaveStartedContinuation = nil
            await withCheckedContinuation { continuation in
                readySaveReleaseContinuation = continuation
            }
        }
        if storesReadyOutcome && (failsReadyOutcome || readyFailuresRemaining > 0) {
            observedReadyFailures += 1
            if readyFailuresRemaining > 0 { readyFailuresRemaining -= 1 }
            throw SpeechFixtureError.manifestWriteFailed
        }
        try await backing.save(manifest, expectedRevision: expectedRevision)
    }
}

private actor AuthorizationFailingStore: SessionManifestStore {
    private let backing = InMemorySessionManifestStore()
    private var authorizationFailuresRemaining = 0
    private var observedAuthorizationSaves = 0
    private var observedAuthorizationFailures = 0

    func failNextAuthorizationOnce() { authorizationFailuresRemaining = 1 }
    func authorizationSaveCount() -> Int { observedAuthorizationSaves }
    func authorizationFailureCount() -> Int { observedAuthorizationFailures }

    func load(sessionID: SessionID) async throws -> SessionManifest? {
        await backing.load(sessionID: sessionID)
    }

    func save(_ manifest: SessionManifest, expectedRevision: Int?) async throws {
        let storesAuthorization = manifest.interviewerUtterances.contains(where: {
            $0.synthesisAttempts.last?.lifecycle == .authorized
        })
        if storesAuthorization {
            observedAuthorizationSaves += 1
            if authorizationFailuresRemaining > 0 {
                authorizationFailuresRemaining -= 1
                observedAuthorizationFailures += 1
                throw SpeechFixtureError.manifestWriteFailed
            }
        }
        try await backing.save(manifest, expectedRevision: expectedRevision)
    }
}

private enum SpeechFixtureError: Error {
    case unused
    case missingWrite
    case manifestWriteFailed
    case producerDidNotStart
}
