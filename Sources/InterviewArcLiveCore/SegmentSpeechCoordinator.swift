import Foundation

public enum SegmentSpeechCoordinatorError: Error, Sendable, Equatable {
    case noActiveSegment
    case segmentAudioUnavailable(SegmentID)
    case captureFailed(SegmentCaptureFailureReason)
    case credentialUnavailable
    case transcriptionFailed(SegmentTranscriptionFailureReason)
}

/// UI-facing deep Module for segmented candidate speech. It is the sole owner
/// of capture/transcription orchestration: durable command authorization is
/// always observed before an Adapter side effect, and an idempotent replay is
/// never interpreted as permission to invoke that side effect again.
@MainActor
public final class SegmentSpeechCoordinator {
    public private(set) var snapshot: InterviewRoomSnapshot

    private let session: InterviewRoomSession
    private let recording: any SegmentRecording
    private let transcriber: any SegmentTranscribing
    private let credentialReader: any GroqCredentialReading
    private var snapshotHandler: (@MainActor @Sendable (InterviewRoomSnapshot) -> Void)?
    private var isFinalizing = false

    private init(
        session: InterviewRoomSession,
        initialSnapshot: InterviewRoomSnapshot,
        recording: any SegmentRecording,
        transcriber: any SegmentTranscribing,
        credentialReader: any GroqCredentialReading
    ) {
        self.session = session
        snapshot = initialSnapshot
        self.recording = recording
        self.transcriber = transcriber
        self.credentialReader = credentialReader
        installUnexpectedTerminationHandler()
    }

    /// Observes the canonical persisted Session projection. Registration
    /// immediately emits the current Snapshot; every later persisted
    /// transition emits again, including background capture recovery.
    public func setSnapshotHandler(
        _ handler: (@MainActor @Sendable (InterviewRoomSnapshot) -> Void)?
    ) {
        snapshotHandler = handler
        handler?(snapshot)
    }

    /// Opens one canonical Session, hiding start-versus-restore and recovery
    /// ordering from the app model.
    public static func open(
        sessionID: SessionID,
        activityID: String,
        turnMode: TurnMode = .manual,
        manifestStore: any SessionManifestStore,
        interviewerRuntime: any InterviewerRuntime,
        recording: any SegmentRecording,
        transcriber: any SegmentTranscribing,
        credentialReader: any GroqCredentialReading
    ) async throws -> SegmentSpeechCoordinator {
        let session: InterviewRoomSession
        if try await manifestStore.load(sessionID: sessionID) == nil {
            session = try await InterviewRoomSession.start(
                sessionID: sessionID,
                activityID: activityID,
                turnMode: turnMode,
                manifestStore: manifestStore,
                interviewerRuntime: interviewerRuntime
            )
        } else {
            session = try await InterviewRoomSession.restore(
                sessionID: sessionID,
                manifestStore: manifestStore,
                interviewerRuntime: interviewerRuntime
            )
        }

        return SegmentSpeechCoordinator(
            session: session,
            initialSnapshot: await session.snapshot(),
            recording: recording,
            transcriber: transcriber,
            credentialReader: credentialReader
        )
    }

    /// Production convenience factory. The Adapter still owns private audio
    /// location/adoption; this factory owns only the canonical Manifest store.
    public static func openLocal(
        sessionID: SessionID,
        activityID: String,
        turnMode: TurnMode = .manual,
        interviewerRuntime: any InterviewerRuntime,
        recording: any SegmentRecording,
        transcriber: any SegmentTranscribing,
        credentialReader: any GroqCredentialReading
    ) async throws -> SegmentSpeechCoordinator {
        try await open(
            sessionID: sessionID,
            activityID: activityID,
            turnMode: turnMode,
            manifestStore: FileSessionManifestStore(),
            interviewerRuntime: interviewerRuntime,
            recording: recording,
            transcriber: transcriber,
            credentialReader: credentialReader
        )
    }

    @discardableResult
    public func giveCandidateFloor(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(.giveCandidateFloor(commandID: commandID)).snapshot
    }

    @discardableResult
    public func setTurnMode(
        _ mode: TurnMode,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(.setTurnMode(commandID: commandID, mode: mode)).snapshot
    }

    @discardableResult
    public func retryInterviewerResponse(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(.retryInterviewerResponse(commandID: commandID)).snapshot
    }

    @discardableResult
    public func beginSegment(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let application = try await applyAndPublish(.beginSegment(commandID: commandID))
        guard application.disposition == .accepted else {
            return application.snapshot
        }
        guard let segment = application.snapshot.segments.first(where: {
            $0.reservationCommandID == commandID
        }) else {
            throw SegmentSpeechCoordinatorError.noActiveSegment
        }

        let request = SegmentCaptureRequest(
            sessionID: application.snapshot.sessionID,
            segmentID: segment.id,
            reservedAudioIdentity: segment.reservedAudioIdentity
        )
        do {
            try await recording.beginCapture(request)
        } catch {
            _ = try await applyAndPublish(
                .recordSegmentCaptureOutcome(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: commandID,
                        operation: "capture-start-failed"
                    ),
                    segmentID: segment.id,
                    outcome: .failed(.captureStartFailed)
                )
            )
            throw SegmentSpeechCoordinatorError.captureFailed(.captureStartFailed)
        }

        do {
            return try await applyAndPublish(
                .recordSegmentCaptureOutcome(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: commandID,
                        operation: "capture-started"
                    ),
                    segmentID: segment.id,
                    outcome: .recordingStarted
                )
            ).snapshot
        } catch {
            // The microphone side effect already started. Preserve/stop it
            // without relabeling a persistence failure as capture failure.
            await preserveCaptureAfterStartPersistenceFailure(
                segment: segment,
                sourceCommandID: commandID
            )
            throw error
        }
    }

    /// Stops and durably preserves the active source M4A without invoking a
    /// transcription provider. A fresh command ID explicitly retries a prior
    /// recorder-stop failure while the Segment remains finalization-authorized.
    @discardableResult
    public func finalizeSegment(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await finalizeActiveSegment(commandID: commandID)
    }

    /// Compatibility convenience for the original Stop-and-transcribe flow.
    /// New UI orchestration may call `finalizeSegment` and `transcribeSegment`
    /// separately to expose recovery state between the two operations.
    @discardableResult
    public func finishSegment(
        commandID: CommandID,
        transcriptionCommandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        guard let segmentID = snapshot.segments.first(where: {
            $0.lifecycle == .captureAuthorized
                || $0.lifecycle == .recording
                || $0.lifecycle == .finalizationAuthorized
        })?.id else {
            throw SegmentSpeechCoordinatorError.noActiveSegment
        }
        let finalized = try await finalizeSegment(commandID: commandID)
        guard finalized.segments.first(where: { $0.id == segmentID })?.lifecycle == .audioReady else {
            return finalized
        }
        return try await transcribeSegment(
            segmentID: segmentID,
            commandID: transcriptionCommandID
        )
    }

    /// User-initiated transcription for either a newly recovered source or a
    /// prior failed attempt. Core selects the valid attempt kind; presentation
    /// code does not duplicate lifecycle rules.
    @discardableResult
    public func transcribeSegment(
        segmentID: SegmentID,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        guard let segment = snapshot.segments.first(where: { $0.id == segmentID }) else {
            throw SegmentSpeechCoordinatorError.segmentAudioUnavailable(segmentID)
        }
        let kind: SegmentTranscriptionKind = segment.transcriptionAttempts.isEmpty
            ? .initial
            : .retry
        return try await transcribe(
            segmentID: segmentID,
            kind: kind,
            commandID: commandID
        )
    }

    @discardableResult
    public func retryTranscription(
        segmentID: SegmentID,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await transcribeSegment(segmentID: segmentID, commandID: commandID)
    }

    @discardableResult
    public func excludeSegment(
        segmentID: SegmentID,
        reason: SegmentExclusionReason,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(
            .excludeSegment(commandID: commandID, segmentID: segmentID, reason: reason)
        ).snapshot
    }

    @discardableResult
    public func handOff(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(.handOffSegments(commandID: commandID)).snapshot
    }

    @discardableResult
    public func finishSession(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(.finish(commandID: commandID)).snapshot
    }

    public func playbackURL(segmentID: SegmentID) async throws -> URL {
        guard let segment = snapshot.segments.first(where: { $0.id == segmentID }),
              let audio = segment.capturedAudio else {
            throw SegmentSpeechCoordinatorError.segmentAudioUnavailable(segmentID)
        }
        return try await recording.playbackURL(
            sessionID: snapshot.sessionID,
            audioIdentity: audio.audioIdentity
        )
    }

    /// Reconciles interrupted capture and provider-authorized states. It never
    /// replays a provider request or automatically transcribes a recovered
    /// partial; the user must explicitly call `transcribeSegment` afterward.
    @discardableResult
    public func resumePendingWork() async throws -> InterviewRoomSnapshot {
        publish(await session.snapshot())

        let interruptedAttempts = snapshot.segments.compactMap { segment in
            segment.transcriptionAttempts.first(where: { $0.state == .authorized }).map {
                (segment.id, $0)
            }
        }
        for (segmentID, attempt) in interruptedAttempts {
            _ = try await applyAndPublish(
                .recordSegmentTranscriptionOutcome(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: attempt.authorizationCommandID,
                        operation: "interrupted-transcription-outcome"
                    ),
                    segmentID: segmentID,
                    attemptID: attempt.id,
                    outcome: .failed(
                        SegmentTranscriptionFailure(
                            reason: .interrupted,
                            credentialFingerprint: attempt.credentialFingerprint
                        )
                    )
                )
            )
        }

        let pending = snapshot.segments.filter {
            $0.lifecycle == .captureAuthorized
                || $0.lifecycle == .recording
                || $0.lifecycle == .finalizationAuthorized
        }

        for segment in pending {
            let recoveryRoot = InterviewRoomSession.derivedCommandID(
                source: segment.reservationCommandID,
                operation: "capture-recovery-finalization"
            )
            let authorization = try await applyAndPublish(
                .finalizeSegment(commandID: recoveryRoot, segmentID: segment.id)
            )

            let request = SegmentCaptureRequest(
                sessionID: authorization.snapshot.sessionID,
                segmentID: segment.id,
                reservedAudioIdentity: segment.reservedAudioIdentity
            )
            let outcome: SegmentCaptureOutcome
            do {
                if let capture = try await recording.recoverCapture(request) {
                    outcome = .finalized(capture)
                } else {
                    outcome = .failed(.interruptedWithoutAudio)
                }
            } catch {
                outcome = .failed(.storageFailed)
            }
            _ = try await applyAndPublish(
                .recordSegmentCaptureOutcome(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: recoveryRoot,
                        operation: "capture-recovery-outcome"
                    ),
                    segmentID: segment.id,
                    outcome: outcome
                )
            )
        }
        return snapshot
    }

    private func finalizeActiveSegment(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        guard !isFinalizing else { return snapshot }
        guard let segment = snapshot.segments.first(where: {
            $0.lifecycle == .captureAuthorized
                || $0.lifecycle == .recording
                || $0.lifecycle == .finalizationAuthorized
        }) else {
            throw SegmentSpeechCoordinatorError.noActiveSegment
        }
        isFinalizing = true
        defer { isFinalizing = false }

        let authorization = try await applyAndPublish(
            .finalizeSegment(commandID: commandID, segmentID: segment.id)
        )
        guard authorization.disposition == .accepted else {
            return authorization.snapshot
        }

        let request = SegmentCaptureRequest(
            sessionID: authorization.snapshot.sessionID,
            segmentID: segment.id,
            reservedAudioIdentity: segment.reservedAudioIdentity
        )
        let capture: CapturedAudioSegment
        do {
            capture = try await recording.finishCapture()
        } catch {
            if let recovered = try? await recording.recoverCapture(request) {
                return try await recordFinalizedCapture(
                    recovered,
                    segmentID: segment.id,
                    sourceCommandID: commandID
                )
            }
            // Keep the durable authorization intact. A later explicit Stop
            // with a fresh command ID may safely retry the recorder side effect.
            throw SegmentSpeechCoordinatorError.captureFailed(.captureFinalizationFailed)
        }

        return try await recordFinalizedCapture(
            capture,
            segmentID: segment.id,
            sourceCommandID: commandID
        )
    }

    private func recordFinalizedCapture(
        _ capture: CapturedAudioSegment,
        segmentID: SegmentID,
        sourceCommandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(
            .recordSegmentCaptureOutcome(
                commandID: InterviewRoomSession.derivedCommandID(
                    source: sourceCommandID,
                    operation: "capture-finalized"
                ),
                segmentID: segmentID,
                outcome: .finalized(capture)
            )
        ).snapshot
    }

    private func preserveCaptureAfterStartPersistenceFailure(
        segment: CandidateSegment,
        sourceCommandID: CommandID
    ) async {
        let recoveryRoot = InterviewRoomSession.derivedCommandID(
            source: sourceCommandID,
            operation: "capture-start-persistence-recovery"
        )
        do {
            _ = try await applyAndPublish(
                .finalizeSegment(commandID: recoveryRoot, segmentID: segment.id)
            )
        } catch {
            // The durable authorization may still be unavailable. Stop the
            // microphone best-effort; `resumePendingWork` can adopt the file
            // from the original capture reservation after restart.
            _ = try? await recording.finishCapture()
            publish(await session.snapshot())
            return
        }

        guard let capture = try? await recording.finishCapture() else { return }
        _ = try? await applyAndPublish(
            .recordSegmentCaptureOutcome(
                commandID: InterviewRoomSession.derivedCommandID(
                    source: recoveryRoot,
                    operation: "capture-finalized"
                ),
                segmentID: segment.id,
                outcome: .finalized(capture)
            )
        )
    }

    private func transcribe(
        segmentID: SegmentID,
        kind: SegmentTranscriptionKind,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let credential: String
        do {
            credential = try await credentialReader.readGroqCredential()
        } catch {
            return try await recordUnavailableCredential(
                segmentID: segmentID,
                kind: kind,
                commandID: commandID
            )
        }
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await recordUnavailableCredential(
                segmentID: segmentID,
                kind: kind,
                commandID: commandID
            )
        }

        let fingerprint = InterviewRoomSession.credentialFingerprint(credential)
        let authorization = try await applyAndPublish(
            .authorizeSegmentTranscription(
                commandID: commandID,
                segmentID: segmentID,
                kind: kind,
                credentialFingerprint: fingerprint
            )
        )
        guard authorization.disposition == .accepted else {
            return authorization.snapshot
        }
        guard let segment = authorization.snapshot.segments.first(where: { $0.id == segmentID }),
              let audio = segment.capturedAudio,
              let attempt = segment.transcriptionAttempts.first(where: {
                  $0.authorizationCommandID == commandID
              }) else {
            throw SegmentSpeechCoordinatorError.segmentAudioUnavailable(segmentID)
        }

        let request = SegmentTranscriptionRequest(
            sessionID: authorization.snapshot.sessionID,
            segmentID: segmentID,
            attemptID: attempt.id,
            kind: kind,
            audioIdentity: audio.audioIdentity
        )
        let outcome: SegmentTranscriptionOutcome
        do {
            let result = try await transcriber.transcribe(request, credential: credential)
            if result.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outcome = .failed(
                    SegmentTranscriptionFailure(
                        reason: .emptyProviderResult,
                        credentialFingerprint: fingerprint
                    )
                )
            } else {
                outcome = .candidate(result)
            }
        } catch let failure as SegmentTranscriptionAdapterFailure {
            outcome = .failed(
                SegmentTranscriptionFailure(
                    reason: failure.reason,
                    providerCode: failure.providerCode,
                    credentialFingerprint: fingerprint
                )
            )
        } catch {
            outcome = .failed(
                SegmentTranscriptionFailure(
                    reason: .providerUnavailable,
                    providerCode: .unknown,
                    credentialFingerprint: fingerprint
                )
            )
        }

        let recorded = try await applyAndPublish(
            .recordSegmentTranscriptionOutcome(
                commandID: InterviewRoomSession.derivedCommandID(
                    source: commandID,
                    operation: "transcription-outcome"
                ),
                segmentID: segmentID,
                attemptID: attempt.id,
                outcome: outcome
            )
        ).snapshot
        if case .failed(let failure) = outcome {
            throw SegmentSpeechCoordinatorError.transcriptionFailed(failure.reason)
        }
        return recorded
    }

    private func recordUnavailableCredential(
        segmentID: SegmentID,
        kind: SegmentTranscriptionKind,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let fingerprint = InterviewRoomSession.credentialFingerprint("")
        let authorization = try await applyAndPublish(
            .authorizeSegmentTranscription(
                commandID: commandID,
                segmentID: segmentID,
                kind: kind,
                credentialFingerprint: fingerprint
            )
        )
        guard authorization.disposition == .accepted,
              let segment = authorization.snapshot.segments.first(where: { $0.id == segmentID }),
              let attempt = segment.transcriptionAttempts.first(where: {
                  $0.authorizationCommandID == commandID
              }) else {
            return authorization.snapshot
        }
        _ = try await applyAndPublish(
            .recordSegmentTranscriptionOutcome(
                commandID: InterviewRoomSession.derivedCommandID(
                    source: commandID,
                    operation: "missing-credential"
                ),
                segmentID: segmentID,
                attemptID: attempt.id,
                outcome: .failed(
                    SegmentTranscriptionFailure(
                        reason: .missingCredential,
                        credentialFingerprint: fingerprint
                    )
                )
            )
        )
        throw SegmentSpeechCoordinatorError.credentialUnavailable
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

    private func publish(_ nextSnapshot: InterviewRoomSnapshot) {
        snapshot = nextSnapshot
        snapshotHandler?(nextSnapshot)
    }

    private func installUnexpectedTerminationHandler() {
        recording.setUnexpectedTerminationHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleUnexpectedTermination()
            }
        }
    }

    private func handleUnexpectedTermination() async {
        guard !isFinalizing,
              let segment = snapshot.segments.first(where: { $0.lifecycle == .recording }) else {
            return
        }
        let finalizeCommand = InterviewRoomSession.derivedCommandID(
            source: segment.reservationCommandID,
            operation: "unexpected-finalization"
        )
        _ = try? await finalizeActiveSegment(commandID: finalizeCommand)
    }
}
