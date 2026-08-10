import Foundation

public enum InterviewerSpeechCoordinatorError: Error, Sendable, Equatable {
    case modelNotReady
    case muted
    case operationInProgress(SynthesisAttemptID)
    case playbackInProgress
    case modelPreparationInProgress
    case utteranceNotFound(InterviewerUtteranceID)
    case canonicalTurnNotFound(TurnID)
    case noSelectedAudio(InterviewerUtteranceID)
    case selectedAudioInvalid(InterviewerUtteranceID)
    case invalidProviderAudio
    case providerFailed
    case storageFailed
    case playbackFailed
}

/// Deep Module owning local interviewer speech ordering. Its Interface keeps
/// automatic eligibility, durable authorization, provider streaming, WAV
/// finalization, playback single-flight, cancellation, and recovery local.
/// The canonical Interviewer Turn remains usable regardless of every outcome.
@MainActor
public final class InterviewerSpeechCoordinator {
    private static let maximumAutomaticDrainRetryAttempts = 3
    private static let automaticDrainRetryBaseDelayMilliseconds = 100

    public private(set) var snapshot: InterviewRoomSnapshot
    public private(set) var readiness: InterviewerSpeechReadiness
    public private(set) var isMuted: Bool
    public private(set) var preparationProgress: InterviewerSpeechPreparationProgress?
    public private(set) var lastGenerationMetrics: InterviewerSpeechGenerationMetrics?

    private struct ActiveOperation {
        let utteranceID: InterviewerUtteranceID
        let attemptID: SynthesisAttemptID
        let authorizationCommandID: CommandID
        var task: Task<Void, Never>?
    }

    private struct CancellationFinalizer {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let session: InterviewRoomSession
    private let provider: any InterviewerSpeechProvider
    private let player: any InterviewerSpeechPlaying
    private let audioStore: any InterviewerSpeechAudioStoring
    private var knownInterviewerTurnIDs: Set<TurnID>
    /// Process-local eligibility memory. Restored history is seeded into
    /// `knownInterviewerTurnIDs` at attach and can never enter this queue.
    private var pendingAutomaticTurnIDs: [TurnID] = []
    private var pendingAutomaticTurnIDSet: Set<TurnID> = []
    private var isDrainingAutomaticTurns = false
    private var automaticDrainRetryTask: Task<Void, Never>?
    private var automaticDrainRetryID: UUID?
    private var automaticDrainRetryTurnID: TurnID?
    private var automaticDrainRetryAttemptCount = 0
    private var activeOperation: ActiveOperation?
    private var cancellationFinalizer: CancellationFinalizer?
    private var isPlayingSavedAudio = false
    private var isPreparingModel = false
    private var preparationToken = 0
    private var snapshotHandler: (@MainActor @Sendable (InterviewRoomSnapshot) -> Void)?
    private var readinessHandler: (@MainActor @Sendable (InterviewerSpeechReadiness) -> Void)?

    private init(
        session: InterviewRoomSession,
        initialSnapshot: InterviewRoomSnapshot,
        readiness: InterviewerSpeechReadiness,
        provider: any InterviewerSpeechProvider,
        player: any InterviewerSpeechPlaying,
        audioStore: any InterviewerSpeechAudioStoring,
        initiallyMuted: Bool
    ) {
        self.session = session
        snapshot = initialSnapshot
        self.readiness = readiness
        self.provider = provider
        self.player = player
        self.audioStore = audioStore
        isMuted = initiallyMuted
        knownInterviewerTurnIDs = Set(initialSnapshot.turns.compactMap { turn in
            guard case .interviewer(let interviewer) = turn else { return nil }
            return interviewer.id
        })
    }

    /// Attaches to the existing room writer. Readiness inspection is the only
    /// provider call and is contractually side-effect free; restored Turns are
    /// remembered so attach can never auto-speak history.
    public static func attach(
        to conversation: SegmentSpeechCoordinator,
        provider: any InterviewerSpeechProvider,
        player: any InterviewerSpeechPlaying,
        audioStore: any InterviewerSpeechAudioStoring,
        initiallyMuted: Bool = false
    ) async throws -> InterviewerSpeechCoordinator {
        let currentReadiness = await provider.readiness()
        let currentSnapshot = await conversation.interviewRoomSession.snapshot()
        return InterviewerSpeechCoordinator(
            session: conversation.interviewRoomSession,
            initialSnapshot: currentSnapshot,
            readiness: currentReadiness,
            provider: provider,
            player: player,
            audioStore: audioStore,
            initiallyMuted: initiallyMuted
        )
    }

    public func setSnapshotHandler(
        _ handler: (@MainActor @Sendable (InterviewRoomSnapshot) -> Void)?
    ) {
        snapshotHandler = handler
        handler?(snapshot)
    }

    public func setReadinessHandler(
        _ handler: (@MainActor @Sendable (InterviewerSpeechReadiness) -> Void)?
    ) {
        readinessHandler = handler
        handler?(readiness)
    }

    @discardableResult
    public func refreshReadiness() async -> InterviewerSpeechReadiness {
        let next = await provider.readiness()
        publishReadiness(next)
        if next == .ready {
            resetAutomaticDrainRetry()
            await startNextPendingAutomaticTurnIfEligible()
        }
        return next
    }

    /// A transfer can start only through `.userAuthorizedDownload`. Calling
    /// this with `.neverDownload` is inspection/verification without transfer.
    @discardableResult
    public func prepareModel(
        policy: InterviewerSpeechPreparationPolicy
    ) async throws -> InterviewerSpeechReadiness {
        if let operation = activeOperation {
            throw InterviewerSpeechCoordinatorError.operationInProgress(operation.attemptID)
        }
        guard !isPreparingModel else {
            throw InterviewerSpeechCoordinatorError.modelPreparationInProgress
        }
        isPreparingModel = true
        preparationToken += 1
        let token = preparationToken
        do {
            let next = try await provider.prepare(policy) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard preparationToken == token else { return }
                    preparationProgress = progress
                    publishReadiness(.preparing(progress))
                }
            }
            preparationToken += 1
            preparationProgress = nil
            publishReadiness(next)
            isPreparingModel = false
            if next == .ready {
                resetAutomaticDrainRetry()
                await startNextPendingAutomaticTurnIfEligible()
            }
            return next
        } catch {
            preparationToken += 1
            preparationProgress = nil
            let recoveredReadiness = await provider.readiness()
            publishReadiness(recoveredReadiness)
            isPreparingModel = false
            if recoveredReadiness == .ready {
                resetAutomaticDrainRetry()
                await startNextPendingAutomaticTurnIfEligible()
            }
            throw error
        }
    }

    @discardableResult
    public func removeModel() async throws -> InterviewerSpeechReadiness {
        guard !isPreparingModel else {
            throw InterviewerSpeechCoordinatorError.modelPreparationInProgress
        }
        isPreparingModel = true
        defer { isPreparingModel = false }
        resetAutomaticDrainRetry()
        pendingAutomaticTurnIDs.removeAll()
        pendingAutomaticTurnIDSet.removeAll()
        if let operation = activeOperation {
            try await stop(
                commandID: InterviewRoomSession.derivedCommandID(
                    source: operation.authorizationCommandID,
                    operation: "remove-model-stop"
                )
            )
        }
        await provider.unload()
        do {
            let next = try await provider.removePreparedModel()
            publishReadiness(next)
            return next
        } catch {
            publishReadiness(await provider.readiness())
            throw error
        }
    }

    /// Receives the canonical snapshot returned by the room after a command.
    /// Only an Interviewer Turn not present at attach/previous observation is
    /// eligible for automatic synthesis, and only when already ready/unmuted.
    public func observeNewlyPersistedSnapshot(
        _ observed: InterviewRoomSnapshot
    ) async {
        let observedTurnIDs = observed.turns.compactMap { turn -> TurnID? in
            guard case .interviewer(let interviewer) = turn else { return nil }
            return interviewer.id
        }
        let newlyPersisted = observedTurnIDs.filter {
            !knownInterviewerTurnIDs.contains($0)
        }
        knownInterviewerTurnIDs.formUnion(observedTurnIDs)
        publish(await session.snapshot())

        guard readiness == .ready, !isMuted else { return }
        let pendingTurnIDs = Set(snapshot.interviewerUtterances.lazy.compactMap { utterance in
            utterance.lifecycle == .pending ? utterance.turnID : nil
        })
        for turnID in newlyPersisted {
            guard pendingTurnIDs.contains(turnID) else {
                continue
            }
            if pendingAutomaticTurnIDSet.insert(turnID).inserted {
                pendingAutomaticTurnIDs.append(turnID)
            }
        }
        await startNextPendingAutomaticTurnIfEligible()
    }

    /// Backfills legacy Manifests and reconciles authorized work. It never
    /// invokes the provider or player and never downloads a model.
    @discardableResult
    public func resumePendingWork() async throws -> InterviewRoomSnapshot {
        _ = try await applyAndPublish(
            .backfillInterviewerUtterances(
                commandID: CommandID("interviewer-speech-backfill-v1")
            )
        )
        knownInterviewerTurnIDs.formUnion(snapshot.turns.compactMap { turn in
            guard case .interviewer(let interviewer) = turn else { return nil }
            return interviewer.id
        })

        let interrupted = snapshot.interviewerUtterances.flatMap { utterance in
            utterance.synthesisAttempts.compactMap { attempt in
                (attempt.lifecycle == .authorized || attempt.lifecycle == .speaking)
                    ? (utterance.id, attempt)
                    : nil
            }
        }
        for (utteranceID, attempt) in interrupted {
            let request = InterviewerSpeechAudioRecoveryRequest(
                sessionID: snapshot.sessionID,
                utteranceID: utteranceID,
                attemptID: attempt.id,
                partialAudioIdentity: attempt.partialAudioIdentity,
                finalAudioIdentity: attempt.finalAudioIdentity
            )
            let recovered: InterviewerSpeechAudioArtifact?
            do {
                recovered = try await audioStore.recoverFinalizedAudio(request)
            } catch {
                // Inspection failure is not evidence that a deterministic
                // final WAV is absent. Keep authorization active for retry.
                throw InterviewerSpeechCoordinatorError.storageFailed
            }
            if let recovered,
               recovered.isValidFinalAudio(
                   expectedIdentity: attempt.finalAudioIdentity
               ),
               await audioStore.validateAudio(
                   sessionID: snapshot.sessionID,
                   artifact: recovered
               ) {
                do {
                    _ = try await applyAndPublish(
                        .recordInterviewerSynthesisOutcome(
                            commandID: InterviewRoomSession.derivedCommandID(
                                source: attempt.authorizationCommandID,
                                operation: "adopt-recovered-interviewer-audio"
                            ),
                            utteranceID: utteranceID,
                            attemptID: attempt.id,
                            outcome: .ready(recovered)
                        )
                    )
                    continue
                } catch InterviewRoomSessionError.invalidSynthesisAudio {
                    // A structurally present but provenance-inconsistent file
                    // is not adoptable and must require explicit Retry.
                }
            }
            await audioStore.discardPartial(attemptID: attempt.id)
            _ = try await applyAndPublish(
                .recordInterviewerSynthesisOutcome(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: attempt.authorizationCommandID,
                        operation: "interrupted-interviewer-synthesis"
                    ),
                    utteranceID: utteranceID,
                    attemptID: attempt.id,
                    outcome: .failed(
                        InterviewerSynthesisFailure(reason: .interrupted)
                    )
                )
            )
        }
        return snapshot
    }

    /// Explicitly synthesizes a pending or prior-attempt Utterance. Model
    /// preparation is never hidden here; the exact revision must already be ready.
    public func retry(
        utteranceID: InterviewerUtteranceID,
        commandID: CommandID
    ) async throws {
        guard let utterance = snapshot.interviewerUtterances.first(where: {
            $0.id == utteranceID
        }) else {
            throw InterviewerSpeechCoordinatorError.utteranceNotFound(utteranceID)
        }
        try await authorizeAndStart(
            utteranceID: utteranceID,
            kind: utterance.synthesisAttempts.isEmpty ? .initial : .retry,
            commandID: commandID
        )
    }

    public func stop(commandID: CommandID) async throws {
        await player.stop()
        isPlayingSavedAudio = false
        if let finalizer = cancellationFinalizer {
            try await finalizer.task.value
            return
        }
        guard let operation = activeOperation else {
            return
        }
        try await finalizeCancellation(
            of: operation,
            commandID: commandID,
            reason: .userStopped
        )
    }

    /// Mute is a local preference, not Manifest history. Muting stops current
    /// output; unmuting never replays or synthesizes prior content.
    public func setMuted(_ muted: Bool, commandID: CommandID) async throws {
        guard muted != isMuted else { return }
        isMuted = muted
        guard muted else { return }
        resetAutomaticDrainRetry()
        pendingAutomaticTurnIDs.removeAll()
        pendingAutomaticTurnIDSet.removeAll()
        await player.stop()
        isPlayingSavedAudio = false
        if let finalizer = cancellationFinalizer {
            try await finalizer.task.value
            return
        }
        if let operation = activeOperation {
            try await finalizeCancellation(
                of: operation,
                commandID: commandID,
                reason: .muted
            )
        }
    }

    /// Plays only a selected, validated WAV. No provider call is possible.
    public func play(utteranceID: InterviewerUtteranceID) async throws {
        guard !isMuted else { throw InterviewerSpeechCoordinatorError.muted }
        if let operation = activeOperation {
            throw InterviewerSpeechCoordinatorError.operationInProgress(operation.attemptID)
        }
        guard !isPlayingSavedAudio else {
            throw InterviewerSpeechCoordinatorError.playbackInProgress
        }
        guard let utterance = snapshot.interviewerUtterances.first(where: {
            $0.id == utteranceID
        }) else {
            throw InterviewerSpeechCoordinatorError.utteranceNotFound(utteranceID)
        }
        guard let audio = utterance.selectedAudio else {
            throw InterviewerSpeechCoordinatorError.noSelectedAudio(utteranceID)
        }
        isPlayingSavedAudio = true
        defer { isPlayingSavedAudio = false }
        guard await audioStore.validateAudio(
            sessionID: snapshot.sessionID,
            artifact: audio
        ) else {
            throw InterviewerSpeechCoordinatorError.selectedAudioInvalid(utteranceID)
        }
        try await player.play(
            InterviewerSpeechPlaybackRequest(
                sessionID: snapshot.sessionID,
                artifact: audio
            )
        )
    }

    /// Deterministic verification hook. Production presentation need not wait;
    /// generation continues in the coordinator-owned Task.
    public func waitUntilIdle() async {
        while true {
            if let task = activeOperation?.task {
                await task.value
                continue
            }
            if let task = automaticDrainRetryTask {
                await task.value
                continue
            }
            return
        }
    }

    private func authorizeAndStart(
        utteranceID: InterviewerUtteranceID,
        kind: SynthesisAttemptKind,
        commandID: CommandID
    ) async throws {
        if let stored = snapshot.interviewerUtterances.lazy
            .flatMap({ utterance in
                utterance.synthesisAttempts.map { (utterance.id, $0) }
            })
            .first(where: { $0.1.authorizationCommandID == commandID }),
           stored.0 == utteranceID {
            // Reconstruct the already-durable Generate payload exactly. In
            // particular, an initial command replayed after its terminal
            // outcome must not be reinterpreted as a Retry, and replay remains
            // zero-effect while muted, unavailable, or another operation runs.
            _ = try await applyAndPublish(
                .authorizeInterviewerSynthesis(
                    commandID: commandID,
                    utteranceID: utteranceID,
                    kind: stored.1.kind,
                    provenance: stored.1.provenance
                )
            )
            return
        }
        guard readiness == .ready else {
            throw InterviewerSpeechCoordinatorError.modelNotReady
        }
        guard !isPreparingModel else {
            throw InterviewerSpeechCoordinatorError.modelPreparationInProgress
        }
        guard !isMuted else { throw InterviewerSpeechCoordinatorError.muted }
        if let operation = activeOperation {
            throw InterviewerSpeechCoordinatorError.operationInProgress(operation.attemptID)
        }
        if isPlayingSavedAudio {
            await player.stop()
            isPlayingSavedAudio = false
        }
        guard let utterance = snapshot.interviewerUtterances.first(where: {
            $0.id == utteranceID
        }) else {
            throw InterviewerSpeechCoordinatorError.utteranceNotFound(utteranceID)
        }
        guard let turn = interviewerTurn(turnID: utterance.turnID) else {
            throw InterviewerSpeechCoordinatorError.canonicalTurnNotFound(utterance.turnID)
        }

        let authorization = try await applyAndPublish(
            .authorizeInterviewerSynthesis(
                commandID: commandID,
                utteranceID: utteranceID,
                kind: kind,
                provenance: provider.provenance
            )
        )
        guard authorization.disposition == .accepted,
              let authorizedUtterance = authorization.snapshot.interviewerUtterances
                .first(where: { $0.id == utteranceID }),
              let attempt = authorizedUtterance.synthesisAttempts.first(where: {
                  $0.authorizationCommandID == commandID
              }) else {
            return
        }

        let request = InterviewerSpeechSynthesisRequest(
            sessionID: authorization.snapshot.sessionID,
            turnID: turn.id,
            utteranceID: utteranceID,
            attemptID: attempt.id,
            spokenText: turn.spokenText,
            profile: provider.provenance.profile
        )
        activeOperation = ActiveOperation(
            utteranceID: utteranceID,
            attemptID: attempt.id,
            authorizationCommandID: commandID,
            task: nil
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runGeneration(
                request: request,
                attempt: attempt,
                authorizationCommandID: commandID
            )
            await self.generationDidFinish(attemptID: attempt.id)
        }
        activeOperation?.task = task
    }

    private func runGeneration(
        request: InterviewerSpeechSynthesisRequest,
        attempt: SynthesisAttempt,
        authorizationCommandID: CommandID
    ) async {
        let writeRequest = InterviewerSpeechAudioWriteRequest(
            sessionID: request.sessionID,
            utteranceID: request.utteranceID,
            attemptID: request.attemptID,
            partialAudioIdentity: attempt.partialAudioIdentity,
            finalAudioIdentity: attempt.finalAudioIdentity
        )
        var observedChunkCount = 0
        var observedSampleCount = 0
        var didPersistSpeaking = false
        var completion: InterviewerSpeechGenerationMetrics?
        var finalizedAudio: InterviewerSpeechAudioArtifact?

        do {
            let prepared: InterviewerSpeechReadiness
            do {
                prepared = try await provider.prepare(.neverDownload) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard activeOperation?.attemptID == request.attemptID else { return }
                        preparationProgress = progress
                        publishReadiness(.preparing(progress))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw InterviewerSpeechCoordinatorError.modelNotReady
            }
            try Task.checkCancellation()
            preparationProgress = nil
            publishReadiness(prepared)
            guard prepared == .ready else {
                throw InterviewerSpeechCoordinatorError.modelNotReady
            }
            do {
                try await audioStore.beginWrite(writeRequest)
            } catch {
                throw InterviewerSpeechCoordinatorError.storageFailed
            }
            try Task.checkCancellation()
            do {
                try await player.beginStreaming(sampleRate: 24_000, channelCount: 1)
            } catch {
                throw InterviewerSpeechCoordinatorError.playbackFailed
            }
            try Task.checkCancellation()
            let stream = try await provider.synthesize(request)
            try Task.checkCancellation()
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .pcm(let chunk):
                    try Self.validate(
                        chunk: chunk,
                        accumulatedSamples: observedSampleCount
                    )
                    guard completion == nil else {
                        throw InterviewerSpeechCoordinatorError.invalidProviderAudio
                    }
                    if !didPersistSpeaking {
                        _ = try await applyAndPublish(
                            .recordInterviewerSynthesisSpeaking(
                                commandID: InterviewRoomSession.derivedCommandID(
                                    source: authorizationCommandID,
                                    operation: "interviewer-synthesis-speaking"
                                ),
                                utteranceID: request.utteranceID,
                                attemptID: request.attemptID
                            )
                        )
                        didPersistSpeaking = true
                        try Task.checkCancellation()
                    }
                    do {
                        try await audioStore.append(chunk, attemptID: request.attemptID)
                    } catch {
                        throw InterviewerSpeechCoordinatorError.storageFailed
                    }
                    try Task.checkCancellation()
                    do {
                        try await player.enqueue(chunk)
                    } catch {
                        throw InterviewerSpeechCoordinatorError.playbackFailed
                    }
                    try Task.checkCancellation()
                    observedChunkCount += 1
                    observedSampleCount += chunk.samples.count

                case .completed(let metrics):
                    guard completion == nil,
                          metrics.chunkCount == observedChunkCount,
                          metrics.generatedSampleCount == observedSampleCount,
                          metrics.chunkCount > 0,
                          metrics.generatedSampleCount > 0,
                          Self.valid(milliseconds: metrics.timeToFirstAudioMilliseconds),
                          Self.valid(milliseconds: metrics.totalGenerationMilliseconds) else {
                        throw InterviewerSpeechCoordinatorError.invalidProviderAudio
                    }
                    completion = metrics
                }
            }
            guard observedChunkCount > 0,
                  observedSampleCount > 0,
                  let completion else {
                throw InterviewerSpeechCoordinatorError.invalidProviderAudio
            }
            let audio: InterviewerSpeechAudioArtifact
            do {
                audio = try await audioStore.finalizeWrite(attemptID: request.attemptID)
            } catch {
                throw InterviewerSpeechCoordinatorError.storageFailed
            }
            guard audio.isValidFinalAudio(expectedIdentity: attempt.finalAudioIdentity) else {
                throw InterviewerSpeechCoordinatorError.invalidProviderAudio
            }
            finalizedAudio = audio
            try Task.checkCancellation()
            do {
                try await player.finishStreaming()
            } catch {
                await player.stop()
            }
            try Task.checkCancellation()
            let readyCommand = InterviewRoomCommand.recordInterviewerSynthesisOutcome(
                commandID: InterviewRoomSession.derivedCommandID(
                    source: authorizationCommandID,
                    operation: "interviewer-synthesis-ready"
                ),
                utteranceID: request.utteranceID,
                attemptID: request.attemptID,
                outcome: .ready(audio)
            )
            do {
                _ = try await applyAndPublish(readyCommand)
            } catch {
                // The atomically renamed WAV is recovery evidence. Never
                // overwrite this authorized Attempt with a failed outcome if
                // the final Manifest save is the operation that failed. Make
                // one persistence-only reconciliation attempt so a transient
                // write failure does not require relaunch; never rerun speech.
                await player.stop()
                guard !Task.isCancelled else { return }
                _ = try? await applyAndPublish(readyCommand)
                return
            }
            lastGenerationMetrics = completion
        } catch is CancellationError {
            // Stop/Mute owns the durable cancellation receipt. The cancelled
            // Task performs no competing outcome transition.
        } catch {
            await player.stop()
            if finalizedAudio != nil {
                // A valid final rename is recoverable on relaunch. Preserve
                // the active durable authorization for adoption.
                return
            }
            await audioStore.discardPartial(attemptID: request.attemptID)
            guard !Task.isCancelled else { return }
            let reason: InterviewerSynthesisFailureReason
            switch error as? InterviewerSpeechCoordinatorError {
            case .modelNotReady:
                reason = .modelUnavailable
            case .invalidProviderAudio:
                reason = .invalidAudio
            case .storageFailed:
                reason = .storageFailed
            case .playbackFailed:
                reason = .playbackFailed
            default:
                reason = .providerFailed
            }
            _ = try? await applyAndPublish(
                .recordInterviewerSynthesisOutcome(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: authorizationCommandID,
                        operation: "interviewer-synthesis-failed"
                    ),
                    utteranceID: request.utteranceID,
                    attemptID: request.attemptID,
                    outcome: .failed(InterviewerSynthesisFailure(reason: reason))
                )
            )
        }
    }

    private static func validate(
        chunk: InterviewerSpeechPCMChunk,
        accumulatedSamples: Int
    ) throws {
        guard chunk.sampleRate == 24_000,
              chunk.channelCount == 1,
              !chunk.samples.isEmpty,
              chunk.samples.allSatisfy(\.isFinite),
              accumulatedSamples <= 2_400_000 - chunk.samples.count else {
            throw InterviewerSpeechCoordinatorError.invalidProviderAudio
        }
    }

    private static func valid(milliseconds: Int64?) -> Bool {
        guard let milliseconds else { return true }
        return milliseconds >= 0
    }

    private func generationDidFinish(attemptID: SynthesisAttemptID) async {
        guard activeOperation?.attemptID == attemptID else { return }
        activeOperation = nil
        await startNextPendingAutomaticTurnIfEligible()
    }

    /// Starts at most one queued automatic Turn. The head is removed only after
    /// durable authorization succeeds, so transient persistence or global
    /// active-attempt conflicts do not silently discard a newly eligible Turn.
    private func startNextPendingAutomaticTurnIfEligible() async {
        guard readiness == .ready,
              !isMuted,
              !isPreparingModel,
              cancellationFinalizer == nil,
              !isDrainingAutomaticTurns,
              activeOperation == nil else {
            return
        }
        isDrainingAutomaticTurns = true
        defer { isDrainingAutomaticTurns = false }

        while let turnID = pendingAutomaticTurnIDs.first {
            guard let utterance = snapshot.interviewerUtterances.first(where: {
                $0.turnID == turnID
            }), utterance.lifecycle == .pending else {
                pendingAutomaticTurnIDs.removeFirst()
                pendingAutomaticTurnIDSet.remove(turnID)
                resetAutomaticDrainRetry(for: turnID)
                continue
            }
            do {
                try await authorizeAndStart(
                    utteranceID: utterance.id,
                    kind: .initial,
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: commandID(for: turnID),
                        operation: "automatic-interviewer-synthesis"
                    )
                )
            } catch {
                scheduleAutomaticDrainRetry(for: turnID)
                return
            }
            pendingAutomaticTurnIDs.removeFirst()
            pendingAutomaticTurnIDSet.remove(turnID)
            resetAutomaticDrainRetry(for: turnID)
            if activeOperation != nil { return }
        }
    }

    /// A failed durable authorization retains the FIFO head and schedules one
    /// delayed retry at a time. The deterministic command ID makes every retry
    /// idempotent, while the capped attempts and backoff prevent a busy loop.
    private func scheduleAutomaticDrainRetry(for turnID: TurnID) {
        guard pendingAutomaticTurnIDs.first == turnID,
              automaticDrainRetryTask == nil else {
            return
        }
        if automaticDrainRetryTurnID != turnID {
            automaticDrainRetryTurnID = turnID
            automaticDrainRetryAttemptCount = 0
        }
        guard automaticDrainRetryAttemptCount < Self.maximumAutomaticDrainRetryAttempts else {
            return
        }

        let delayMilliseconds = Self.automaticDrainRetryBaseDelayMilliseconds
            * (1 << automaticDrainRetryAttemptCount)
        automaticDrainRetryAttemptCount += 1
        let retryID = UUID()
        automaticDrainRetryID = retryID
        automaticDrainRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard let self, automaticDrainRetryID == retryID else { return }
            automaticDrainRetryTask = nil
            automaticDrainRetryID = nil
            await startNextPendingAutomaticTurnIfEligible()
        }
    }

    private func resetAutomaticDrainRetry(for turnID: TurnID? = nil) {
        guard turnID == nil || automaticDrainRetryTurnID == turnID else { return }
        automaticDrainRetryTask?.cancel()
        automaticDrainRetryTask = nil
        automaticDrainRetryID = nil
        automaticDrainRetryTurnID = nil
        automaticDrainRetryAttemptCount = 0
    }

    /// The first Stop/Mute caller owns the durable outcome. Reentrant callers
    /// join the same Task instead of racing a second receipt or clearing an
    /// operation gate while cancellation is still in flight.
    private func finalizeCancellation(
        of operation: ActiveOperation,
        commandID: CommandID,
        reason: InterviewerSynthesisStopReason
    ) async throws {
        if let existing = cancellationFinalizer {
            try await existing.task.value
            return
        }
        let finalizerID = UUID()
        let task = Task { @MainActor [self] in
            operation.task?.cancel()
            await provider.cancelSynthesis()
            await operation.task?.value
            await audioStore.discardPartial(attemptID: operation.attemptID)
            if isDurablyActive(
                utteranceID: operation.utteranceID,
                attemptID: operation.attemptID
            ) {
                _ = try await applyAndPublish(
                    .recordInterviewerSynthesisOutcome(
                        commandID: commandID,
                        utteranceID: operation.utteranceID,
                        attemptID: operation.attemptID,
                        outcome: .stopped(reason)
                    )
                )
            }
            if activeOperation?.attemptID == operation.attemptID {
                activeOperation = nil
            }
        }
        cancellationFinalizer = CancellationFinalizer(id: finalizerID, task: task)
        do {
            try await task.value
        } catch {
            if cancellationFinalizer?.id == finalizerID {
                cancellationFinalizer = nil
            }
            await startNextPendingAutomaticTurnIfEligible()
            throw error
        }
        if cancellationFinalizer?.id == finalizerID {
            cancellationFinalizer = nil
        }
        await startNextPendingAutomaticTurnIfEligible()
    }

    private func interviewerTurn(turnID: TurnID) -> InterviewerTurn? {
        snapshot.turns.lazy.compactMap { turn -> InterviewerTurn? in
            guard case .interviewer(let interviewer) = turn else { return nil }
            return interviewer
        }.first(where: { $0.id == turnID })
    }

    private func isDurablyActive(
        utteranceID: InterviewerUtteranceID,
        attemptID: SynthesisAttemptID
    ) -> Bool {
        guard let attempt = snapshot.interviewerUtterances
            .first(where: { $0.id == utteranceID })?
            .synthesisAttempts.first(where: { $0.id == attemptID }) else {
            return false
        }
        return attempt.lifecycle == .authorized || attempt.lifecycle == .speaking
    }

    private func commandID(for turnID: TurnID) -> CommandID {
        guard let turn = interviewerTurn(turnID: turnID) else {
            return CommandID("missing-interviewer-turn")
        }
        return turn.commandID
    }

    private func applyAndPublish(
        _ command: InterviewRoomCommand
    ) async throws -> InterviewRoomCommandApplication {
        do {
            let application = try await session.apply(command)
            publish(application.snapshot)
            return application
        } catch {
            publish(await session.snapshot())
            throw error
        }
    }

    private func publish(_ next: InterviewRoomSnapshot) {
        snapshot = next
        snapshotHandler?(next)
    }

    private func publishReadiness(_ next: InterviewerSpeechReadiness) {
        readiness = next
        readinessHandler?(next)
    }
}
