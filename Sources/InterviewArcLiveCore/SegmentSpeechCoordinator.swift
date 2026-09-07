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

    /// Internal handoff to the interviewer-speech Module. The application
    /// never receives the mutable Session actor directly.
    var interviewRoomSession: InterviewRoomSession { session }

    private let session: InterviewRoomSession
    private let recording: any SegmentRecording
    private let transcriber: any SegmentTranscribing
    private let credentialReader: any GroqCredentialReading
    private let semanticEndpointClassifier: any SemanticEndpointClassifying
    private let endpointGraceScheduler: any EndpointGraceScheduling
    private let acousticSegmenter: (any AcousticSegmenting)?
    private let boundaryTracer: (any ConversationBoundaryTracing)?
    private var snapshotHandler: (@MainActor @Sendable (InterviewRoomSnapshot) -> Void)?
    private var interviewerPlaybackStopper:
        (@MainActor @Sendable (CommandID, InterviewerSynthesisStopReason) async throws -> Void)?
    private var isFinalizing = false
    private var isHandlingAcousticEvent = false
    private var isHandlingBargeIn = false
    private var wantsContinuousListening = false
    private var armedAcousticMode: AcousticSegmentationMode = .disarmed
    private var endpointGraceTask: Task<Void, Never>?

    private init(
        session: InterviewRoomSession,
        initialSnapshot: InterviewRoomSnapshot,
        recording: any SegmentRecording,
        transcriber: any SegmentTranscribing,
        credentialReader: any GroqCredentialReading,
        semanticEndpointClassifier: (any SemanticEndpointClassifying)?,
        endpointGraceScheduler: any EndpointGraceScheduling,
        acousticSegmenter: (any AcousticSegmenting)?,
        boundaryTracer: (any ConversationBoundaryTracing)?
    ) {
        self.session = session
        snapshot = initialSnapshot
        self.recording = recording
        self.transcriber = transcriber
        self.credentialReader = credentialReader
        self.endpointGraceScheduler = endpointGraceScheduler
        self.acousticSegmenter = acousticSegmenter
        self.boundaryTracer = boundaryTracer
        if let semanticEndpointClassifier {
            self.semanticEndpointClassifier = semanticEndpointClassifier
        } else {
            self.semanticEndpointClassifier = GroqEndpointClassifier(
                credentialReader: credentialReader
            )
        }
        acousticSegmenter?.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleAcousticEvent(event)
            }
        }
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
        activityPrompt: ActivityPrompt,
        turnMode: TurnMode = .continuousConversation,
        manifestStore: any SessionManifestStore,
        interviewerRuntime: any InterviewerRuntime,
        recording: any SegmentRecording,
        transcriber: any SegmentTranscribing,
        credentialReader: any GroqCredentialReading,
        semanticEndpointClassifier: (any SemanticEndpointClassifying)? = nil,
        endpointGraceScheduler: any EndpointGraceScheduling = ContinuousEndpointGraceScheduler(),
        acousticSegmenter: (any AcousticSegmenting)? = nil,
        boundaryTracer: (any ConversationBoundaryTracing)? = nil
    ) async throws -> SegmentSpeechCoordinator {
        let session: InterviewRoomSession
        if try await manifestStore.load(sessionID: sessionID) == nil {
            session = try await InterviewRoomSession.start(
                sessionID: sessionID,
                activityID: activityID,
                activityPrompt: activityPrompt,
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
            credentialReader: credentialReader,
            semanticEndpointClassifier: semanticEndpointClassifier,
            endpointGraceScheduler: endpointGraceScheduler,
            acousticSegmenter: acousticSegmenter,
            boundaryTracer: boundaryTracer
        )
    }

    /// Production convenience factory. The Adapter still owns private audio
    /// location/adoption; this factory owns only the canonical Manifest store.
    public static func openLocal(
        sessionID: SessionID,
        activityID: String,
        activityPrompt: ActivityPrompt,
        turnMode: TurnMode = .continuousConversation,
        interviewerRuntime: any InterviewerRuntime,
        recording: any SegmentRecording,
        transcriber: any SegmentTranscribing,
        credentialReader: any GroqCredentialReading,
        semanticEndpointClassifier: (any SemanticEndpointClassifying)? = nil,
        endpointGraceScheduler: any EndpointGraceScheduling = ContinuousEndpointGraceScheduler(),
        acousticSegmenter: (any AcousticSegmenting)? = nil,
        boundaryTracer: (any ConversationBoundaryTracing)? = nil
    ) async throws -> SegmentSpeechCoordinator {
        try await open(
            sessionID: sessionID,
            activityID: activityID,
            activityPrompt: activityPrompt,
            turnMode: turnMode,
            manifestStore: FileSessionManifestStore(),
            interviewerRuntime: interviewerRuntime,
            recording: recording,
            transcriber: transcriber,
            credentialReader: credentialReader,
            semanticEndpointClassifier: semanticEndpointClassifier,
            endpointGraceScheduler: endpointGraceScheduler,
            acousticSegmenter: acousticSegmenter,
            boundaryTracer: boundaryTracer
        )
    }

    @discardableResult
    public func giveCandidateFloor(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let next = try await applyAndPublish(.giveCandidateFloor(commandID: commandID)).snapshot
        await armContinuousListeningIfNeeded()
        return next
    }

    @discardableResult
    public func requestOpeningInterviewerTurn(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(
            .requestOpeningInterviewerTurn(commandID: commandID)
        ).snapshot
    }

    @discardableResult
    public func setTurnMode(
        _ mode: TurnMode,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let next = try await applyAndPublish(
            .setTurnMode(commandID: commandID, mode: mode)
        ).snapshot
        cancelScheduledGraceIfInactive()
        if next.turnMode == .continuousConversation {
            await armContinuousListeningIfNeeded()
        } else {
            wantsContinuousListening = false
            await disarmAcousticSegmenter()
        }
        return next
    }

    @discardableResult
    public func updateCandidateNotes(
        _ notes: CandidateNotes,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let next = try await applyAndPublish(
            .updateCandidateNotes(commandID: commandID, notes: notes)
        ).snapshot
        cancelScheduledGraceIfInactive()
        return next
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
        cancelScheduledGraceIfInactive()
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
    public func updateBoardDraft(
        _ document: BoardDocument,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let next = try await applyAndPublish(
            .updateBoardDraft(commandID: commandID, document: document)
        ).snapshot
        cancelScheduledGraceIfInactive()
        return next
    }

    @discardableResult
    public func saveBoardRevision(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(
            .saveBoardRevision(commandID: commandID)
        ).snapshot
    }

    @discardableResult
    public func selectBoardRevision(
        _ revisionID: BoardRevisionID?,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(
            .selectBoardRevision(commandID: commandID, revisionID: revisionID)
        ).snapshot
    }

    @discardableResult
    public func attachBoardRevision(
        _ revisionID: BoardRevisionID,
        to turnID: TurnID,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(
            .attachBoardRevision(
                commandID: commandID,
                turnID: turnID,
                revisionID: revisionID
            )
        ).snapshot
    }

    /// Returns the durable authorization disposition so an export Adapter is
    /// invoked only for a newly accepted operation.
    @discardableResult
    public func authorizeBoardExport(
        revisionID: BoardRevisionID,
        settings: BoardExportSettings,
        commandID: CommandID
    ) async throws -> InterviewRoomCommandApplication {
        try await applyAndPublish(
            .authorizeBoardExport(
                commandID: commandID,
                revisionID: revisionID,
                settings: settings
            )
        )
    }

    @discardableResult
    public func recordBoardExportOutcome(
        exportID: BoardExportID,
        outcome: BoardExportOutcome,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        try await applyAndPublish(
            .recordBoardExportOutcome(
                commandID: commandID,
                exportID: exportID,
                outcome: outcome
            )
        ).snapshot
    }

    @discardableResult
    public func handOff(
        commandID: CommandID,
        boardAttachment: CandidateTurnBoardAttachment = .noBoard
    ) async throws -> InterviewRoomSnapshot {
        let next = try await applyAndPublish(
            .handOffSegmentsWithBoard(
                commandID: commandID,
                boardAttachment: boardAttachment
            )
        ).snapshot
        cancelScheduledGrace()
        await disarmAcousticSegmenter()
        return next
    }

    @discardableResult
    public func activateFloorHold(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let next = try await applyAndPublish(
            .activateFloorHold(commandID: commandID)
        ).snapshot
        cancelScheduledGraceIfInactive()
        trace(
            command: "activate_floor_hold",
            resultCode: "held",
            counts: ["floor_holds": next.floorHolds.count]
        )
        await armContinuousListeningIfNeeded()
        return next
    }

    @discardableResult
    public func sendAnswer(
        commandID: CommandID,
        boardAttachment: CandidateTurnBoardAttachment = .noBoard
    ) async throws -> InterviewRoomSnapshot {
        if snapshot.segments.contains(where: {
            $0.lifecycle == .captureAuthorized
                || $0.lifecycle == .recording
                || $0.lifecycle == .finalizationAuthorized
        }) {
            let finalized = try await finalizeSegment(
                commandID: InterviewRoomSession.derivedCommandID(
                    source: commandID,
                    operation: "send-answer-finalize"
                )
            )
            if let segment = finalized.segments.last(where: {
                $0.lifecycle == .audioReady && $0.committedTurnID == nil
            }) {
                _ = try await transcribeSegment(
                    segmentID: segment.id,
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: commandID,
                        operation: "send-answer-transcribe"
                    )
                )
            }
        }

        let next = try await applyAndPublish(
            .sendAnswer(
                commandID: commandID,
                boardAttachment: boardAttachment
            )
        ).snapshot
        cancelScheduledGrace()
        await disarmAcousticSegmenter()
        trace(
            command: "send_answer",
            resultCode: "handed_off",
            counts: [
                "turns": next.turns.count,
                "segments": next.segments.count,
            ]
        )
        return next
    }

    public func enableContinuousListening() async {
        wantsContinuousListening = true
        await armContinuousListeningIfNeeded()
    }

    public func setInterviewerPlaybackStopper(
        _ stopper: (@MainActor @Sendable (CommandID, InterviewerSynthesisStopReason) async throws -> Void)?
    ) {
        interviewerPlaybackStopper = stopper
    }

    /// Arms echo-cleaned speech-start detection while interviewer TTS plays.
    /// Candidate capture stays off until barge-in is confirmed or playback ends.
    public func noteInterviewerPlaybackStarted() async {
        guard wantsContinuousListening,
              snapshot.turnMode == .continuousConversation else {
            return
        }
        await acousticSegmenter?.arm(.bargeInDetection)
        armedAcousticMode = .bargeInDetection
        trace(command: "arm_listening", resultCode: "barge_in_detection")
    }

    /// Opens Candidate Floor and re-arms normal listening after uninterrupted
    /// playback. Barge-in owns the same transition when it confirms speech.
    public func noteInterviewerPlaybackFinished() async {
        guard !isHandlingBargeIn else { return }
        guard wantsContinuousListening,
              snapshot.turnMode == .continuousConversation else {
            return
        }
        if snapshot.phase == .interviewerTurn || snapshot.phase == .ready {
            let commandID = InterviewRoomSession.derivedCommandID(
                source: CommandID("continuous-\(snapshot.revision)"),
                operation: "playback-complete-floor"
            )
            do {
                _ = try await giveCandidateFloor(commandID: commandID)
            } catch {
                trace(command: "playback_complete", resultCode: "floor_failed")
            }
        }
        await armContinuousListeningIfNeeded()
    }

    @discardableResult
    public func pauseMicrophone(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        wantsContinuousListening = false
        await disarmAcousticSegmenter()
        trace(command: "pause_microphone", resultCode: "disarmed")
        if snapshot.segments.contains(where: {
            $0.lifecycle == .captureAuthorized
                || $0.lifecycle == .recording
                || $0.lifecycle == .finalizationAuthorized
        }) {
            return try await finalizeSegment(commandID: commandID)
        }
        return snapshot
    }

    @discardableResult
    public func cancelEndpointGrace(
        graceID: EndpointGraceID,
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        let next = try await applyAndPublish(
            .cancelEndpointGrace(
                commandID: commandID,
                graceID: graceID,
                reason: .keptFloor
            )
        ).snapshot
        cancelScheduledGrace()
        return next
    }

    @discardableResult
    public func finishSession(
        commandID: CommandID
    ) async throws -> InterviewRoomSnapshot {
        // End must quiesce both input and output before committing completion.
        // Otherwise speech completion can reopen the microphone during teardown.
        cancelScheduledGrace()
        wantsContinuousListening = false
        await disarmAcousticSegmenter()
        try await interviewerPlaybackStopper?(
            InterviewRoomSession.derivedCommandID(source: commandID, operation: "finish-speech"),
            .userStopped
        )
        return try await applyAndPublish(.finish(commandID: commandID)).snapshot
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

        cancelScheduledGrace()
        try await reconcileInterruptedEndpointGraces()

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

        let interruptedEvaluations = snapshot.endpointEvaluations.filter {
            $0.lifecycle == .authorized
        }
        for evaluation in interruptedEvaluations {
            _ = try await applyAndPublish(
                .reconcileInterruptedEndpointEvaluation(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: evaluation.authorizationCommandID,
                        operation: "interrupted-endpoint-evaluation"
                    ),
                    evaluationID: evaluation.id
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
        let previouslySelectedCandidateID = segment.selectedCandidateID

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
        guard case .candidate = outcome,
              let recordedSegment = recorded.segments.first(where: { $0.id == segmentID }),
              recordedSegment.selectedCandidateID != previouslySelectedCandidateID else {
            return recorded
        }
        return await evaluateEndpointIfNeeded(
            triggerSegmentID: segmentID,
            sourceCommandID: commandID
        )
    }

    /// Patient Auto evaluates one explicit completed-Segment boundary. A
    /// current likely-end proposal may start the durable Endpoint Grace; only
    /// grace completion can commit the Candidate Turn and invoke the
    /// interviewer runtime.
    private func evaluateEndpointIfNeeded(
        triggerSegmentID: SegmentID,
        sourceCommandID: CommandID
    ) async -> InterviewRoomSnapshot {
        guard snapshot.phase == .candidateFloor,
              snapshot.turnMode.usesAutomaticEndpointCompletion else {
            return snapshot
        }

        let draftSegments = snapshot.segments.filter { $0.committedTurnID == nil }
        let unresolvedDraft = draftSegments.contains {
            $0.lifecycle != .excluded
                && ($0.lifecycle == .captureAuthorized
                    || $0.lifecycle == .recording
                    || $0.lifecycle == .finalizationAuthorized
                    || $0.lifecycle == .transcribing
                    || $0.selectedCandidate == nil)
        }
        guard !unresolvedDraft else { return snapshot }

        let selectedSegments = draftSegments
            .filter { $0.lifecycle != .excluded && $0.selectedCandidate != nil }
            .sorted { $0.ordinal < $1.ordinal }
        guard let triggerSegment = selectedSegments.first(where: { $0.id == triggerSegmentID }),
              let triggerBody = triggerSegment.selectedCandidate?.body else {
            return snapshot
        }
        let latestSegment = triggerBody.trimmingCharacters(in: .whitespacesAndNewlines)

        let selectedCandidateIDs = selectedSegments.compactMap(\.selectedCandidateID)
        let accumulatedBodies = selectedSegments.compactMap {
            $0.selectedCandidate?.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard selectedCandidateIDs.count == selectedSegments.count,
              accumulatedBodies.count == selectedSegments.count,
              !latestSegment.isEmpty,
              accumulatedBodies.allSatisfy({ !$0.isEmpty }) else {
            return snapshot
        }

        let latestQuestionTurn: InterviewerTurn? = snapshot.turns.reversed().lazy.compactMap {
            guard case .interviewer(let turn) = $0 else { return nil }
            return turn
        }.first
        let questionTurnID = latestQuestionTurn?.id
        let context = SemanticEndpointContext(
            interviewerQuestion: latestQuestionTurn?.displayMarkdown
                ?? snapshot.activityPrompt.question,
            requestedParts: questionTurnID == nil
                ? snapshot.activityPrompt.requestedParts
                : [],
            accumulatedAnswer: accumulatedBodies.joined(separator: "\n\n"),
            latestSegment: latestSegment,
            silenceDurationMilliseconds: 0,
            specialty: snapshot.activityPrompt.specialty.rawValue,
            stage: snapshot.activityPrompt.stage,
            explicitCue: false,
            workspaceActivity: []
        )
        let contextFingerprint: String
        do {
            contextFingerprint = try InterviewRoomSession.endpointContextFingerprint(
                context,
                triggerSegmentID: triggerSegmentID,
                selectedCandidateIDs: selectedCandidateIDs,
                questionTurnID: questionTurnID
            )
        } catch {
            // Semantic evaluation is subordinate to transcription. The
            // selected transcript is already durable and remains the
            // successful result of this operation.
            return snapshot
        }
        let authorizationCommandID = InterviewRoomSession.derivedCommandID(
            source: sourceCommandID,
            operation: "endpoint-evaluation-authorization"
        )
        let authorization: InterviewRoomCommandApplication
        do {
            authorization = try await applyAndPublish(
                .authorizeEndpointEvaluation(
                    commandID: authorizationCommandID,
                    triggerSegmentID: triggerSegmentID,
                    selectedCandidateIDs: selectedCandidateIDs,
                    questionTurnID: questionTurnID,
                    contextFingerprint: contextFingerprint
                )
            )
        } catch {
            // Authorization persistence and concurrent ineligibility never
            // relabel a durably successful transcription as failed.
            publish(await session.snapshot())
            return snapshot
        }
        guard authorization.disposition == .accepted else {
            return authorization.snapshot
        }
        guard let evaluation = authorization.snapshot.endpointEvaluations.first(where: {
            $0.authorizationCommandID == authorizationCommandID
        }) else {
            return authorization.snapshot
        }

        let outcome: EndpointEvaluationOutcome
        do {
            outcome = .proposal(try await semanticEndpointClassifier.classify(context))
        } catch {
            outcome = .failed(Self.endpointFailure(for: error))
        }
        do {
            let outcomeCommandID = InterviewRoomSession.derivedCommandID(
                source: authorizationCommandID,
                operation: "endpoint-evaluation-outcome"
            )
            let recorded = try await applyAndPublish(
                .recordEndpointEvaluationOutcome(
                    commandID: outcomeCommandID,
                    evaluationID: evaluation.id,
                    outcome: outcome
                )
            ).snapshot
            guard case .proposal(let proposal) = outcome,
                  proposal.decision == .likelyEnd,
                  recorded.endpointEvaluations.first(where: {
                      $0.id == evaluation.id
                  })?.lifecycle == .proposalStored else {
                return recorded
            }
            return await activateEndpointGraceIfEligible(
                evaluationID: evaluation.id,
                sourceCommandID: outcomeCommandID
            )
        } catch {
            return await reconcileEndpointEvaluation(
                evaluation,
                authorizationCommandID: authorizationCommandID
            )
        }
    }

    private func activateEndpointGraceIfEligible(
        evaluationID: EndpointEvaluationID,
        sourceCommandID: CommandID
    ) async -> InterviewRoomSnapshot {
        guard snapshot.floorHolds.activeHold == nil else {
            await armContinuousListeningIfNeeded()
            return snapshot
        }
        guard let expectedBoardAttachment = BoardHandoffAttachmentPolicy.currentDraftAttachment(
            in: snapshot.board
        ) else {
            await armContinuousListeningIfNeeded()
            return snapshot
        }
        let activationCommandID = InterviewRoomSession.derivedCommandID(
            source: sourceCommandID,
            operation: "endpoint-grace-activation"
        )
        do {
            let application = try await applyAndPublish(
                .activateEndpointGrace(
                    commandID: activationCommandID,
                    evaluationID: evaluationID,
                    expectedBoardAttachment: expectedBoardAttachment
                )
            )
            guard application.disposition == .accepted,
                  let grace = application.snapshot.endpointGraces.first(where: {
                      $0.activationCommandID == activationCommandID
                  }),
                  grace.lifecycle == .pending else {
                return application.snapshot
            }
            schedule(grace)
            return application.snapshot
        } catch {
            publish(await session.snapshot())
            return snapshot
        }
    }

    private func reconcileInterruptedEndpointGraces() async throws {
        let interruptedGraces = snapshot.endpointGraces.filter {
            $0.lifecycle == .pending
        }
        for grace in interruptedGraces {
            _ = try await applyAndPublish(
                .reconcileInterruptedEndpointGrace(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: grace.activationCommandID,
                        operation: "interrupted-endpoint-grace"
                    ),
                    graceID: grace.id
                )
            )
        }
    }

    private func schedule(_ grace: EndpointGrace) {
        cancelScheduledGrace()
        endpointGraceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await endpointGraceScheduler.waitForGrace()
            } catch {
                return
            }
            await completeScheduledGrace(grace.id)
        }
    }

    private func completeScheduledGrace(_ graceID: EndpointGraceID) async {
        guard let grace = snapshot.endpointGraces.first(where: {
            $0.id == graceID && $0.lifecycle == .pending
        }) else {
            cancelScheduledGraceIfInactive()
            return
        }
        guard let boardAttachment = BoardHandoffAttachmentPolicy.currentDraftAttachment(
            in: snapshot.board
        ) else {
            _ = try? await applyAndPublish(
                .cancelEndpointGrace(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: grace.activationCommandID,
                        operation: "endpoint-grace-board-ineligible"
                    ),
                    graceID: graceID,
                    reason: .boardActivity
                )
            )
            cancelScheduledGrace()
            return
        }
        do {
            _ = try await applyAndPublish(
                .completeEndpointGrace(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: grace.activationCommandID,
                        operation: "endpoint-grace-complete"
                    ),
                    graceID: graceID,
                    boardAttachment: boardAttachment
                )
            )
        } catch {
            publish(await session.snapshot())
            if snapshot.endpointGraces.contains(where: {
                $0.id == graceID && $0.lifecycle == .pending
            }) {
                _ = try? await applyAndPublish(
                    .reconcileInterruptedEndpointGrace(
                        commandID: InterviewRoomSession.derivedCommandID(
                            source: grace.activationCommandID,
                            operation: "endpoint-grace-completion-interrupted"
                        ),
                        graceID: graceID
                    )
                )
            }
        }
        cancelScheduledGrace()
    }

    private func cancelScheduledGraceIfInactive() {
        guard !snapshot.endpointGraces.contains(where: {
            $0.lifecycle == .pending
        }) else { return }
        cancelScheduledGrace()
    }

    private func cancelScheduledGrace() {
        endpointGraceTask?.cancel()
        endpointGraceTask = nil
    }

    /// Once provider work was durably authorized, an outcome-write failure is
    /// reconciled independently from transcription. A persistent store outage
    /// leaves the authorization recoverable by `resumePendingWork` rather than
    /// reporting the already-stored transcript as failed.
    private func reconcileEndpointEvaluation(
        _ evaluation: EndpointEvaluation,
        authorizationCommandID: CommandID
    ) async -> InterviewRoomSnapshot {
        do {
            return try await applyAndPublish(
                .reconcileInterruptedEndpointEvaluation(
                    commandID: InterviewRoomSession.derivedCommandID(
                        source: authorizationCommandID,
                        operation: "endpoint-evaluation-outcome-recovery"
                    ),
                    evaluationID: evaluation.id
                )
            ).snapshot
        } catch {
            publish(await session.snapshot())
            return snapshot
        }
    }

    private static func endpointFailure(for error: Error) -> EndpointEvaluationFailure {
        guard let classifierError = error as? GroqEndpointClassifierError else {
            return EndpointEvaluationFailure(reason: .transportFailure)
        }
        switch classifierError {
        case .missingCredential:
            return EndpointEvaluationFailure(reason: .missingCredential)
        case .invalidContext, .contextLimitExceeded:
            return EndpointEvaluationFailure(reason: .contextRejected)
        case .transportFailure, .invalidHTTPResponse:
            return EndpointEvaluationFailure(reason: .transportFailure)
        case .rejected(let statusCode):
            return EndpointEvaluationFailure(
                reason: .providerRejected,
                providerStatusCode: statusCode
            )
        case .malformedResponse, .invalidClassification:
            return EndpointEvaluationFailure(reason: .invalidResponse)
        }
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

    private func handleAcousticEvent(_ event: AcousticSegmentationEvent) async {
        guard !isHandlingAcousticEvent else { return }
        isHandlingAcousticEvent = true
        defer { isHandlingAcousticEvent = false }

        switch event {
        case .ignoredNoise:
            trace(command: "acoustic_event", resultCode: "ignored_noise")
        case .speechStarted:
            trace(command: "acoustic_event", resultCode: "speech_started")
            if shouldHandleBargeIn {
                await handleBargeIn()
                return
            }
            guard snapshot.turnMode == .continuousConversation,
                  snapshot.phase == .candidateFloor,
                  canBeginContinuousSegment else { return }
            let commandID = InterviewRoomSession.derivedCommandID(
                source: CommandID("continuous-\(snapshot.revision)"),
                operation: "vad-begin"
            )
            do {
                _ = try await beginSegment(commandID: commandID)
            } catch {
                trace(command: "acoustic_event", resultCode: "speech_start_ignored")
            }
        case .speechEnded:
            trace(command: "acoustic_event", resultCode: "speech_ended")
            guard snapshot.segments.contains(where: {
                $0.lifecycle == .captureAuthorized || $0.lifecycle == .recording
            }) else {
                await armContinuousListeningIfNeeded()
                return
            }
            let commandID = InterviewRoomSession.derivedCommandID(
                source: CommandID("continuous-\(snapshot.revision)"),
                operation: "vad-end"
            )
            do {
                _ = try await finishSegment(
                    commandID: commandID,
                    transcriptionCommandID: InterviewRoomSession.derivedCommandID(
                        source: commandID,
                        operation: "vad-transcribe"
                    )
                )
            } catch {
                trace(command: "acoustic_event", resultCode: "speech_end_failed")
            }
            await armContinuousListeningIfNeeded()
        }
    }

    private var shouldHandleBargeIn: Bool {
        snapshot.turnMode == .continuousConversation
            && wantsContinuousListening
            && (
                armedAcousticMode == .bargeInDetection
                    || snapshot.phase == .interviewerTurn
            )
    }

    private func handleBargeIn() async {
        isHandlingBargeIn = true
        defer { isHandlingBargeIn = false }

        let preRoll = acousticSegmenter?.takeBoundedPreRoll()
        trace(
            command: "acoustic_event",
            resultCode: "barge_in_confirmed",
            counts: ["pre_roll_ms": preRoll?.durationMilliseconds ?? 0]
        )

        let stopCommandID = InterviewRoomSession.derivedCommandID(
            source: CommandID("continuous-\(snapshot.revision)"),
            operation: "barge-in-stop"
        )
        do {
            try await interviewerPlaybackStopper?(stopCommandID, .bargeIn)
        } catch {
            trace(command: "acoustic_event", resultCode: "barge_in_stop_failed")
        }

        if snapshot.phase == .interviewerTurn || snapshot.phase == .ready {
            let floorCommandID = InterviewRoomSession.derivedCommandID(
                source: CommandID("continuous-\(snapshot.revision)"),
                operation: "barge-in-floor"
            )
            do {
                _ = try await giveCandidateFloor(commandID: floorCommandID)
            } catch {
                trace(command: "acoustic_event", resultCode: "barge_in_floor_failed")
                return
            }
        }

        guard snapshot.phase == .candidateFloor, canBeginContinuousSegment else {
            return
        }
        let beginCommandID = InterviewRoomSession.derivedCommandID(
            source: CommandID("continuous-\(snapshot.revision)"),
            operation: "barge-in-begin"
        )
        do {
            _ = try await beginSegment(commandID: beginCommandID)
        } catch {
            trace(command: "acoustic_event", resultCode: "barge_in_begin_failed")
        }
    }

    private var canBeginContinuousSegment: Bool {
        !snapshot.segments.contains {
            $0.committedTurnID == nil
                && ($0.lifecycle == .captureAuthorized
                    || $0.lifecycle == .recording
                    || $0.lifecycle == .finalizationAuthorized
                    || $0.lifecycle == .transcribing)
        }
    }

    private func armContinuousListeningIfNeeded() async {
        guard wantsContinuousListening,
              snapshot.turnMode == .continuousConversation,
              snapshot.phase == .candidateFloor,
              canBeginContinuousSegment else { return }
        await acousticSegmenter?.arm(.candidateListening)
        armedAcousticMode = .candidateListening
        trace(
            command: "arm_listening",
            resultCode: "candidate_listening",
            counts: ["segments": snapshot.segments.count]
        )
    }

    private func disarmAcousticSegmenter() async {
        await acousticSegmenter?.disarm()
        armedAcousticMode = .disarmed
    }

    private func trace(
        command: String,
        resultCode: String,
        counts: [String: Int] = [:]
    ) {
        boundaryTracer?.record(
            ConversationBoundaryEvent(
                command: command,
                phase: snapshot.phase,
                resultCode: resultCode,
                counts: counts
            )
        )
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
