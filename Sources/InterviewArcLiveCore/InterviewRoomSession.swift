import CryptoKit
import Foundation

public enum InterviewRoomCommand: Codable, Sendable, Equatable {
    case giveCandidateFloor(commandID: CommandID)
    case setTurnMode(commandID: CommandID, mode: TurnMode)
    case updateCandidateNotes(commandID: CommandID, notes: CandidateNotes)
    case beginSegment(commandID: CommandID)
    case finalizeSegment(commandID: CommandID, segmentID: SegmentID)
    case recordSegmentCaptureOutcome(
        commandID: CommandID,
        segmentID: SegmentID,
        outcome: SegmentCaptureOutcome
    )
    case authorizeSegmentTranscription(
        commandID: CommandID,
        segmentID: SegmentID,
        kind: SegmentTranscriptionKind,
        credentialFingerprint: String
    )
    case recordSegmentTranscriptionOutcome(
        commandID: CommandID,
        segmentID: SegmentID,
        attemptID: TranscriptionAttemptID,
        outcome: SegmentTranscriptionOutcome
    )
    case authorizeEndpointEvaluation(
        commandID: CommandID,
        triggerSegmentID: SegmentID,
        selectedCandidateIDs: [TranscriptCandidateID],
        questionTurnID: TurnID?,
        contextFingerprint: String
    )
    case recordEndpointEvaluationOutcome(
        commandID: CommandID,
        evaluationID: EndpointEvaluationID,
        outcome: EndpointEvaluationOutcome
    )
    case activateEndpointGrace(
        commandID: CommandID,
        evaluationID: EndpointEvaluationID,
        expectedBoardAttachment: CandidateTurnBoardAttachment
    )
    case cancelEndpointGrace(
        commandID: CommandID,
        graceID: EndpointGraceID,
        reason: EndpointGraceCancellationReason
    )
    case completeEndpointGrace(
        commandID: CommandID,
        graceID: EndpointGraceID,
        boardAttachment: CandidateTurnBoardAttachment
    )
    case reconcileInterruptedEndpointGrace(
        commandID: CommandID,
        graceID: EndpointGraceID
    )
    case activateFloorHold(commandID: CommandID)
    case sendAnswer(
        commandID: CommandID,
        boardAttachment: CandidateTurnBoardAttachment
    )
    case reconcileInterruptedEndpointEvaluation(
        commandID: CommandID,
        evaluationID: EndpointEvaluationID
    )
    case backfillInterviewerUtterances(commandID: CommandID)
    case authorizeInterviewerSynthesis(
        commandID: CommandID,
        utteranceID: InterviewerUtteranceID,
        kind: SynthesisAttemptKind,
        provenance: InterviewerSpeechProvenance
    )
    case recordInterviewerSynthesisSpeaking(
        commandID: CommandID,
        utteranceID: InterviewerUtteranceID,
        attemptID: SynthesisAttemptID
    )
    case recordInterviewerSynthesisOutcome(
        commandID: CommandID,
        utteranceID: InterviewerUtteranceID,
        attemptID: SynthesisAttemptID,
        outcome: InterviewerSynthesisOutcome
    )
    case excludeSegment(
        commandID: CommandID,
        segmentID: SegmentID,
        reason: SegmentExclusionReason
    )
    case updateBoardDraft(commandID: CommandID, document: BoardDocument)
    case saveBoardRevision(commandID: CommandID)
    case selectBoardRevision(commandID: CommandID, revisionID: BoardRevisionID?)
    case attachBoardRevision(
        commandID: CommandID,
        turnID: TurnID,
        revisionID: BoardRevisionID
    )
    case authorizeBoardExport(
        commandID: CommandID,
        revisionID: BoardRevisionID,
        settings: BoardExportSettings
    )
    case recordBoardExportOutcome(
        commandID: CommandID,
        exportID: BoardExportID,
        outcome: BoardExportOutcome
    )
    case handOffSegments(commandID: CommandID)
    case handOffSegmentsWithBoard(
        commandID: CommandID,
        boardAttachment: CandidateTurnBoardAttachment
    )
    case handOff(commandID: CommandID, transcript: CandidateTranscript)
    case handOffWithBoard(
        commandID: CommandID,
        transcript: CandidateTranscript,
        boardAttachment: CandidateTurnBoardAttachment
    )
    case retryInterviewerResponse(commandID: CommandID)
    case finish(commandID: CommandID)

    var commandID: CommandID {
        switch self {
        case .giveCandidateFloor(let commandID),
             .setTurnMode(let commandID, _),
             .updateCandidateNotes(let commandID, _),
             .beginSegment(let commandID),
             .finalizeSegment(let commandID, _),
             .recordSegmentCaptureOutcome(let commandID, _, _),
             .authorizeSegmentTranscription(let commandID, _, _, _),
             .recordSegmentTranscriptionOutcome(let commandID, _, _, _),
             .authorizeEndpointEvaluation(let commandID, _, _, _, _),
             .recordEndpointEvaluationOutcome(let commandID, _, _),
             .activateEndpointGrace(let commandID, _, _),
             .cancelEndpointGrace(let commandID, _, _),
             .completeEndpointGrace(let commandID, _, _),
             .reconcileInterruptedEndpointGrace(let commandID, _),
             .activateFloorHold(let commandID),
             .sendAnswer(let commandID, _),
             .reconcileInterruptedEndpointEvaluation(let commandID, _),
             .backfillInterviewerUtterances(let commandID),
             .authorizeInterviewerSynthesis(let commandID, _, _, _),
             .recordInterviewerSynthesisSpeaking(let commandID, _, _),
             .recordInterviewerSynthesisOutcome(let commandID, _, _, _),
             .excludeSegment(let commandID, _, _),
             .updateBoardDraft(let commandID, _),
             .saveBoardRevision(let commandID),
             .selectBoardRevision(let commandID, _),
             .attachBoardRevision(let commandID, _, _),
             .authorizeBoardExport(let commandID, _, _),
             .recordBoardExportOutcome(let commandID, _, _),
             .handOffSegments(let commandID),
             .handOffSegmentsWithBoard(let commandID, _),
             .handOff(let commandID, _),
             .handOffWithBoard(let commandID, _, _),
             .retryInterviewerResponse(let commandID),
             .finish(let commandID):
            commandID
        }
    }
}

private struct EndpointContextFingerprintEnvelope: Encodable {
    let context: SemanticEndpointContext
    let triggerSegmentID: SegmentID
    let selectedCandidateIDs: [TranscriptCandidateID]
    let questionTurnID: TurnID?
}

public enum InterviewRoomCommandDisposition: Sendable, Equatable {
    case accepted
    case alreadyApplied
}

/// A command receipt lets the coordinator distinguish a newly persisted
/// authorization from an idempotent replay before invoking an external side
/// effect.
public struct InterviewRoomCommandApplication: Sendable, Equatable {
    public let snapshot: InterviewRoomSnapshot
    public let disposition: InterviewRoomCommandDisposition

    init(snapshot: InterviewRoomSnapshot, disposition: InterviewRoomCommandDisposition) {
        self.snapshot = snapshot
        self.disposition = disposition
    }
}

public enum InterviewRoomSessionError: Error, Sendable, Equatable {
    case emptyIdentifier(name: String)
    case sessionAlreadyExists(SessionID)
    case sessionNotFound(SessionID)
    case invalidManifest(reason: String)
    case invalidTransition(command: String, phase: InterviewRoomPhase)
    case emptyCandidateTranscript
    case candidateTranscriptTooLong(maximumUTF8Bytes: Int)
    case invalidInterviewerResponse
    case commandIDReused(CommandID)
    case commandInProgress
    case commandEncodingFailed
    case endpointContextEncodingFailed
    case segmentAlreadyActive(SegmentID)
    case segmentNotFound(SegmentID)
    case invalidSegmentTransition(segmentID: SegmentID, lifecycle: CandidateSegmentLifecycle)
    case invalidCapturedAudio
    case transcriptionAlreadyInProgress(TranscriptionAttemptID)
    case transcriptionAttemptNotFound(TranscriptionAttemptID)
    case invalidTranscriptionAttemptKind
    case invalidCredentialFingerprint
    case rejectedCredentialUnchanged
    case segmentHasInsufficientSignal(SegmentID)
    case invalidTranscriptionOutcome
    case endpointEvaluationNotFound(EndpointEvaluationID)
    case endpointEvaluationAlreadyInProgress(EndpointEvaluationID)
    case endpointEvidenceMismatch
    case invalidEndpointContextFingerprint
    case endpointContextFingerprintReused
    case invalidEndpointEvaluationOutcome
    case invalidEndpointEvaluationTransition(
        evaluationID: EndpointEvaluationID,
        lifecycle: EndpointEvaluationLifecycle
    )
    case endpointGraceNotFound(EndpointGraceID)
    case endpointGraceAlreadyPending(EndpointGraceID)
    case endpointGraceAlreadyExists(EndpointEvaluationID)
    case invalidEndpointGraceTransition(
        graceID: EndpointGraceID,
        lifecycle: EndpointGraceLifecycle
    )
    case endpointGraceEvidenceMismatch
    case floorHoldAlreadyActive(FloorHoldID)
    case floorHoldNotActive
    case floorHoldActive
    case interviewerUtteranceNotFound(InterviewerUtteranceID)
    case synthesisAttemptNotFound(SynthesisAttemptID)
    case synthesisAlreadyInProgress(SynthesisAttemptID)
    case invalidSynthesisAttemptKind
    case invalidSpeechProvenance
    case invalidSynthesisAudio
    case invalidSynthesisTransition(
        attemptID: SynthesisAttemptID,
        lifecycle: SynthesisAttemptLifecycle
    )
    case noTranscribedSegments
    case unresolvedSegmentsPreventHandOff([SegmentID])
    case uncommittedSegmentsRequireSegmentHandOff
    case boardRevisionNotFound(BoardRevisionID)
    case boardTurnNotFound(TurnID)
    case boardAttachmentImmutable(turnID: TurnID)
    case boardExportNotFound(BoardExportID)
    case boardExportAlreadyCompleted(BoardExportID)
    case invalidBoardExportBundle
}

/// Deep Module owning Interview Room ordering, transitions, idempotency,
/// deterministic candidate selection, and persist-before-side-effect rules.
/// Callers receive immutable snapshots and command receipts; SwiftUI never
/// mutates the Session Manifest or orchestrates providers directly.
public actor InterviewRoomSession {
    private var manifest: SessionManifest
    private let manifestStore: any SessionManifestStore
    private let interviewerRuntime: any InterviewerRuntime
    private var isExecutingCommand = false

    private init(
        manifest: SessionManifest,
        manifestStore: any SessionManifestStore,
        interviewerRuntime: any InterviewerRuntime
    ) {
        self.manifest = manifest
        self.manifestStore = manifestStore
        self.interviewerRuntime = interviewerRuntime
    }

    /// Creates and durably records a new session at revision zero.
    public static func start(
        sessionID: SessionID,
        activityID: String,
        activityPrompt: ActivityPrompt,
        turnMode: TurnMode = .continuousConversation,
        manifestStore: any SessionManifestStore,
        interviewerRuntime: any InterviewerRuntime
    ) async throws -> InterviewRoomSession {
        try validateIdentifier(sessionID.rawValue, name: "sessionID")
        try validateIdentifier(activityID, name: "activityID")

        if try await manifestStore.load(sessionID: sessionID) != nil {
            throw InterviewRoomSessionError.sessionAlreadyExists(sessionID)
        }

        let manifest = SessionManifest(
            sessionID: sessionID,
            activityID: activityID,
            activityPrompt: activityPrompt,
            phase: .ready,
            turnMode: turnMode,
            turns: [],
            segments: [],
            revision: 0,
            appliedCommands: []
        )
        try await manifestStore.save(manifest, expectedRevision: nil)

        return InterviewRoomSession(
            manifest: manifest,
            manifestStore: manifestStore,
            interviewerRuntime: interviewerRuntime
        )
    }

    /// Restores the latest complete manifest without advancing its revision.
    public static func restore(
        sessionID: SessionID,
        manifestStore: any SessionManifestStore,
        interviewerRuntime: any InterviewerRuntime
    ) async throws -> InterviewRoomSession {
        try validateIdentifier(sessionID.rawValue, name: "sessionID")

        guard let manifest = try await manifestStore.load(sessionID: sessionID) else {
            throw InterviewRoomSessionError.sessionNotFound(sessionID)
        }
        try validate(manifest)

        return InterviewRoomSession(
            manifest: manifest,
            manifestStore: manifestStore,
            interviewerRuntime: interviewerRuntime
        )
    }

    public func snapshot() -> InterviewRoomSnapshot {
        InterviewRoomSnapshot(manifest: manifest)
    }

    /// Compatibility Interface for callers that do not own an external side
    /// effect. New capture/transcription orchestration uses `apply(_:)` so it
    /// can inspect the durable authorization disposition.
    public func execute(_ command: InterviewRoomCommand) async throws -> InterviewRoomSnapshot {
        try await apply(command).snapshot
    }

    /// Applies one command serially and reports whether this invocation wrote
    /// the authorization or merely observed a prior identical command.
    public func apply(
        _ command: InterviewRoomCommand
    ) async throws -> InterviewRoomCommandApplication {
        guard !isExecutingCommand else {
            throw InterviewRoomSessionError.commandInProgress
        }
        isExecutingCommand = true
        defer { isExecutingCommand = false }

        try Self.validateIdentifier(command.commandID.rawValue, name: "commandID")
        let fingerprint = try Self.fingerprint(for: command)

        if let applied = manifest.appliedCommands.first(where: {
            $0.commandID == command.commandID
        }) {
            guard applied.payloadFingerprint == fingerprint else {
                throw InterviewRoomSessionError.commandIDReused(command.commandID)
            }
            return InterviewRoomCommandApplication(
                snapshot: InterviewRoomSnapshot(manifest: manifest),
                disposition: .alreadyApplied
            )
        }

        if case .authorizeEndpointEvaluation(
            _,
            let triggerSegmentID,
            let selectedCandidateIDs,
            let questionTurnID,
            let contextFingerprint
        ) = command,
           let existing = manifest.endpointEvaluations.first(where: {
               $0.contextFingerprint == contextFingerprint
           }) {
            guard existing.triggerSegmentID == triggerSegmentID,
                  existing.selectedCandidateIDs == selectedCandidateIDs,
                  existing.questionTurnID == questionTurnID else {
                throw InterviewRoomSessionError.endpointContextFingerprintReused
            }
            let deduplicated = appendingReceipt(
                command: command,
                fingerprint: fingerprint,
                phase: manifest.phase,
                turnMode: manifest.turnMode,
                turns: manifest.turns,
                segments: manifest.segments,
                endpointEvaluations: manifest.endpointEvaluations
            )
            try await persist(deduplicated)
            return InterviewRoomCommandApplication(
                snapshot: InterviewRoomSnapshot(manifest: deduplicated),
                disposition: .alreadyApplied
            )
        }

        let snapshot: InterviewRoomSnapshot
        switch command {
        case .handOff(let commandID, let transcript):
            snapshot = try await handOff(
                commandID: commandID,
                transcript: transcript,
                segmentIDs: [],
                boardAttachment: .noBoard,
                endpointGraces: Self.cancellingPendingEndpointGrace(
                    manifest.endpointGraces,
                    reason: .manualHandOff
                ),
                fingerprint: fingerprint
            )

        case .handOffWithBoard(
            let commandID,
            let transcript,
            let boardAttachment
        ):
            snapshot = try await handOff(
                commandID: commandID,
                transcript: transcript,
                segmentIDs: [],
                boardAttachment: boardAttachment,
                endpointGraces: Self.cancellingPendingEndpointGrace(
                    manifest.endpointGraces,
                    reason: .manualHandOff
                ),
                fingerprint: fingerprint
            )

        case .handOffSegments(let commandID):
            snapshot = try await handOffSegments(
                commandID: commandID,
                boardAttachment: .noBoard,
                endpointGraces: Self.cancellingPendingEndpointGrace(
                    manifest.endpointGraces,
                    reason: .manualHandOff
                ),
                fingerprint: fingerprint
            )

        case .handOffSegmentsWithBoard(let commandID, let boardAttachment):
            snapshot = try await handOffSegments(
                commandID: commandID,
                boardAttachment: boardAttachment,
                endpointGraces: Self.cancellingPendingEndpointGrace(
                    manifest.endpointGraces,
                    reason: .manualHandOff
                ),
                fingerprint: fingerprint
            )

        case .completeEndpointGrace(
            let commandID,
            let graceID,
            let boardAttachment
        ):
            snapshot = try await completeEndpointGrace(
                commandID: commandID,
                graceID: graceID,
                boardAttachment: boardAttachment,
                fingerprint: fingerprint
            )

        case .sendAnswer(let commandID, let boardAttachment):
            snapshot = try await sendAnswer(
                commandID: commandID,
                boardAttachment: boardAttachment,
                fingerprint: fingerprint
            )

        case .retryInterviewerResponse(let commandID):
            snapshot = try await retryInterviewerResponse(
                commandID: commandID,
                fingerprint: fingerprint
            )

        default:
            let next = try applyingImmediate(command, fingerprint: fingerprint)
            try await persist(next)
            snapshot = InterviewRoomSnapshot(manifest: next)
        }

        return InterviewRoomCommandApplication(
            snapshot: snapshot,
            disposition: .accepted
        )
    }

    private func applyingImmediate(
        _ command: InterviewRoomCommand,
        fingerprint: String
    ) throws -> SessionManifest {
        var phase = manifest.phase
        var mode = manifest.turnMode
        var segments = manifest.segments
        var endpointEvaluations = manifest.endpointEvaluations
        var endpointGraces = manifest.endpointGraces
        var floorHolds = manifest.floorHolds
        var interviewerUtterances = manifest.interviewerUtterances
        var board = manifest.board
        var candidateNotes = manifest.candidateNotes

        switch command {
        case .giveCandidateFloor:
            guard phase == .ready || phase == .interviewerTurn else {
                throw invalidTransition("giveCandidateFloor")
            }
            phase = .candidateFloor

        case .setTurnMode(_, let selectedMode):
            guard phase != .completed else {
                throw invalidTransition("setTurnMode")
            }
            if mode != selectedMode {
                endpointGraces = Self.cancellingPendingEndpointGrace(
                    endpointGraces,
                    reason: .turnModeChanged
                )
            }
            if mode == .continuousConversation,
               selectedMode != .continuousConversation {
                floorHolds = Self.releasingActiveFloorHold(
                    floorHolds,
                    commandID: command.commandID,
                    reason: .turnModeChanged
                )
            }
            mode = selectedMode

        case .updateCandidateNotes(_, let notes):
            guard phase != .completed else {
                throw invalidTransition("updateCandidateNotes")
            }
            if candidateNotes != notes {
                endpointGraces = Self.cancellingPendingEndpointGrace(
                    endpointGraces,
                    reason: .notesActivity
                )
            }
            candidateNotes = notes

        case .beginSegment(let commandID):
            guard phase == .candidateFloor else {
                throw invalidTransition("beginSegment")
            }
            endpointGraces = Self.cancellingPendingEndpointGrace(
                endpointGraces,
                reason: .resumedSpeech
            )
            if let active = segments.first(where: Self.isActiveSegment) {
                throw InterviewRoomSessionError.segmentAlreadyActive(active.id)
            }
            let segmentID = Self.segmentID(
                sessionID: manifest.sessionID,
                commandID: commandID
            )
            let identity = try SegmentAudioIdentity(
                validating: Self.segmentFileName(segmentID: segmentID)
            )
            segments.append(
                CandidateSegment(
                    id: segmentID,
                    ordinal: segments.count,
                    reservationCommandID: commandID,
                    reservedAudioIdentity: identity,
                    lifecycle: .captureAuthorized
                )
            )

        case .finalizeSegment(_, let segmentID):
            let index = try segmentIndex(segmentID, in: segments)
            guard segments[index].lifecycle == .captureAuthorized
                    || segments[index].lifecycle == .recording
                    || segments[index].lifecycle == .finalizationAuthorized else {
                throw InterviewRoomSessionError.invalidSegmentTransition(
                    segmentID: segmentID,
                    lifecycle: segments[index].lifecycle
                )
            }
            segments[index].lifecycle = .finalizationAuthorized

        case .recordSegmentCaptureOutcome(_, let segmentID, let outcome):
            let index = try segmentIndex(segmentID, in: segments)
            try applyCaptureOutcome(outcome, to: &segments[index])

        case .authorizeSegmentTranscription(
            let commandID,
            let segmentID,
            let kind,
            let credentialFingerprint
        ):
            try Self.validateCredentialFingerprint(credentialFingerprint)
            if let activeAttempt = segments.lazy
                .flatMap(\.transcriptionAttempts)
                .first(where: { $0.state == .authorized }) {
                throw InterviewRoomSessionError.transcriptionAlreadyInProgress(activeAttempt.id)
            }

            let index = try segmentIndex(segmentID, in: segments)
            guard let capturedAudio = segments[index].capturedAudio,
                  capturedAudio.isPlayable,
                  segments[index].lifecycle == .audioReady
                    || segments[index].lifecycle == .transcribed else {
                throw InterviewRoomSessionError.invalidSegmentTransition(
                    segmentID: segmentID,
                    lifecycle: segments[index].lifecycle
                )
            }
            if capturedAudio.integrityReasons.contains(.insufficientSignal) {
                throw InterviewRoomSessionError.segmentHasInsufficientSignal(segmentID)
            }

            let attempts = segments[index].transcriptionAttempts
            switch kind {
            case .initial where !attempts.isEmpty,
                 .retry where attempts.isEmpty:
                throw InterviewRoomSessionError.invalidTranscriptionAttemptKind
            default:
                break
            }

            if kind == .retry,
               attempts.contains(where: {
                   $0.failure?.reason == .credentialRejected
                       && $0.credentialFingerprint == credentialFingerprint
               }) {
                throw InterviewRoomSessionError.rejectedCredentialUnchanged
            }

            let attemptID = Self.attemptID(
                sessionID: manifest.sessionID,
                segmentID: segmentID,
                commandID: commandID
            )
            segments[index].transcriptionAttempts.append(
                SegmentTranscriptionAttempt(
                    id: attemptID,
                    authorizationCommandID: commandID,
                    kind: kind,
                    credentialFingerprint: credentialFingerprint
                )
            )
            segments[index].lifecycle = .transcribing

        case .recordSegmentTranscriptionOutcome(
            _,
            let segmentID,
            let attemptID,
            let outcome
        ):
            let index = try segmentIndex(segmentID, in: segments)
            try applyTranscriptionOutcome(
                outcome,
                attemptID: attemptID,
                to: &segments[index]
            )

        case .authorizeEndpointEvaluation(
            let commandID,
            let triggerSegmentID,
            let selectedCandidateIDs,
            let questionTurnID,
            let contextFingerprint
        ):
            guard phase == .candidateFloor, mode.usesAutomaticEndpointCompletion else {
                throw invalidTransition("authorizeEndpointEvaluation")
            }
            try Self.validateEndpointContextFingerprint(contextFingerprint)
            if let activeEvaluation = endpointEvaluations.first(where: {
                $0.lifecycle == .authorized
            }) {
                throw InterviewRoomSessionError.endpointEvaluationAlreadyInProgress(
                    activeEvaluation.id
                )
            }
            let expectedCandidateIDs = try Self.currentEndpointCandidateIDs(
                in: segments
            )
            guard selectedCandidateIDs == expectedCandidateIDs,
                  Set(selectedCandidateIDs).count == selectedCandidateIDs.count,
                  let triggerSegment = segments.first(where: {
                      $0.id == triggerSegmentID
                  }),
                  triggerSegment.committedTurnID == nil,
                  triggerSegment.lifecycle != .excluded,
                  let triggerCandidateID = triggerSegment.selectedCandidateID,
                  selectedCandidateIDs.contains(triggerCandidateID),
                  questionTurnID == Self.latestInterviewerTurnID(in: manifest.turns) else {
                throw InterviewRoomSessionError.endpointEvidenceMismatch
            }

            endpointEvaluations.append(
                EndpointEvaluation(
                    id: Self.endpointEvaluationID(
                        sessionID: manifest.sessionID,
                        commandID: commandID
                    ),
                    authorizationCommandID: commandID,
                    triggerSegmentID: triggerSegmentID,
                    selectedCandidateIDs: selectedCandidateIDs,
                    questionTurnID: questionTurnID,
                    contextFingerprint: contextFingerprint,
                    lifecycle: .authorized
                )
            )

        case .recordEndpointEvaluationOutcome(_, let evaluationID, let outcome):
            let index = try endpointEvaluationIndex(
                evaluationID,
                in: endpointEvaluations
            )
            guard endpointEvaluations[index].lifecycle == .authorized else {
                throw InterviewRoomSessionError.invalidEndpointEvaluationTransition(
                    evaluationID: evaluationID,
                    lifecycle: endpointEvaluations[index].lifecycle
                )
            }
            try Self.validateEndpointEvaluationOutcome(outcome)
            let recordedOutcome: EndpointEvaluationOutcome
            if case .proposal = outcome,
               !Self.isCurrentEndpointEvaluation(
                   endpointEvaluations[index],
                   phase: phase,
                   mode: mode,
                   turns: manifest.turns,
                   segments: segments
               ) {
                // The classifier completed, but its authorization no longer
                // describes the current Candidate Floor. Consume this result
                // atomically as interrupted so it can never surface as a
                // proposal for stale evidence or strand the authorization.
                recordedOutcome = .failed(
                    EndpointEvaluationFailure(reason: .interrupted)
                )
            } else {
                recordedOutcome = outcome
            }
            endpointEvaluations[index] = Self.recordingEndpointOutcome(
                recordedOutcome,
                for: endpointEvaluations[index]
            )

        case .activateEndpointGrace(
            let commandID,
            let evaluationID,
            let expectedBoardAttachment
        ):
            guard phase == .candidateFloor, mode.usesAutomaticEndpointCompletion else {
                throw invalidTransition("activateEndpointGrace")
            }
            if floorHolds.activeHold != nil {
                throw InterviewRoomSessionError.floorHoldActive
            }
            if let pendingGrace = endpointGraces.first(where: {
                $0.lifecycle == .pending
            }) {
                throw InterviewRoomSessionError.endpointGraceAlreadyPending(
                    pendingGrace.id
                )
            }
            if endpointGraces.contains(where: { $0.evaluationID == evaluationID }) {
                throw InterviewRoomSessionError.endpointGraceAlreadyExists(evaluationID)
            }
            guard let evaluation = endpointEvaluations.first(where: {
                $0.id == evaluationID
            }),
            evaluation.lifecycle == .proposalStored,
            evaluation.proposal?.decision == .likelyEnd,
            Self.isCurrentEndpointEvaluation(
                evaluation,
                phase: phase,
                mode: mode,
                turns: manifest.turns,
                segments: segments
            ) else {
                throw InterviewRoomSessionError.endpointGraceEvidenceMismatch
            }
            guard BoardHandoffAttachmentPolicy.currentDraftAttachment(in: board)
                == expectedBoardAttachment else {
                throw InterviewRoomSessionError.endpointGraceEvidenceMismatch
            }
            endpointGraces.append(
                .pending(
                    id: Self.endpointGraceID(
                        sessionID: manifest.sessionID,
                        commandID: commandID
                    ),
                    activationCommandID: commandID,
                    evaluationID: evaluationID,
                    selectedCandidateIDs: evaluation.selectedCandidateIDs
                )
            )

        case .cancelEndpointGrace(_, let graceID, let reason):
            let index = try endpointGraceIndex(graceID, in: endpointGraces)
            guard endpointGraces[index].lifecycle == .pending else {
                throw InterviewRoomSessionError.invalidEndpointGraceTransition(
                    graceID: graceID,
                    lifecycle: endpointGraces[index].lifecycle
                )
            }
            endpointGraces[index] = endpointGraces[index].cancelling(reason: reason)

        case .reconcileInterruptedEndpointGrace(_, let graceID):
            let index = try endpointGraceIndex(graceID, in: endpointGraces)
            guard endpointGraces[index].lifecycle == .pending else {
                throw InterviewRoomSessionError.invalidEndpointGraceTransition(
                    graceID: graceID,
                    lifecycle: endpointGraces[index].lifecycle
                )
            }
            endpointGraces[index] = endpointGraces[index].cancelling(
                reason: .interrupted
            )

        case .activateFloorHold(let commandID):
            guard phase == .candidateFloor,
                  mode == .continuousConversation else {
                throw invalidTransition("activateFloorHold")
            }
            if let existing = floorHolds.activeHold {
                throw InterviewRoomSessionError.floorHoldAlreadyActive(existing.id)
            }
            endpointGraces = Self.cancellingPendingEndpointGrace(
                endpointGraces,
                reason: .floorHold
            )
            floorHolds.append(
                .active(
                    id: Self.floorHoldID(
                        sessionID: manifest.sessionID,
                        commandID: commandID
                    ),
                    activationCommandID: commandID
                )
            )

        case .reconcileInterruptedEndpointEvaluation(_, let evaluationID):
            let index = try endpointEvaluationIndex(
                evaluationID,
                in: endpointEvaluations
            )
            guard endpointEvaluations[index].lifecycle == .authorized else {
                throw InterviewRoomSessionError.invalidEndpointEvaluationTransition(
                    evaluationID: evaluationID,
                    lifecycle: endpointEvaluations[index].lifecycle
                )
            }
            endpointEvaluations[index] = Self.recordingEndpointOutcome(
                .failed(EndpointEvaluationFailure(reason: .interrupted)),
                for: endpointEvaluations[index]
            )

        case .backfillInterviewerUtterances:
            let representedTurnIDs = Set(interviewerUtterances.map(\.turnID))
            for turn in manifest.turns {
                guard case .interviewer(let interviewer) = turn,
                      !representedTurnIDs.contains(interviewer.id) else {
                    continue
                }
                interviewerUtterances.append(
                    Self.makeInterviewerUtterance(
                        sessionID: manifest.sessionID,
                        turn: interviewer
                    )
                )
            }

        case .authorizeInterviewerSynthesis(
            let commandID,
            let utteranceID,
            let kind,
            let provenance
        ):
            if let active = interviewerUtterances.lazy
                .flatMap(\.synthesisAttempts)
                .first(where: Self.isActiveSynthesisAttempt) {
                throw InterviewRoomSessionError.synthesisAlreadyInProgress(active.id)
            }
            try Self.validateSpeechProvenance(provenance)
            let utteranceIndex = try Self.interviewerUtteranceIndex(
                utteranceID,
                in: interviewerUtterances
            )
            let priorAttempts = interviewerUtterances[utteranceIndex].synthesisAttempts
            switch kind {
            case .initial where !priorAttempts.isEmpty,
                 .retry where priorAttempts.isEmpty:
                throw InterviewRoomSessionError.invalidSynthesisAttemptKind
            default:
                break
            }
            let attemptID = Self.synthesisAttemptID(
                sessionID: manifest.sessionID,
                utteranceID: utteranceID,
                commandID: commandID
            )
            let audioIdentities = try Self.synthesisAudioIdentities(attemptID: attemptID)
            interviewerUtterances[utteranceIndex].synthesisAttempts.append(
                SynthesisAttempt(
                    id: attemptID,
                    authorizationCommandID: commandID,
                    kind: kind,
                    provenance: provenance,
                    partialAudioIdentity: audioIdentities.partial,
                    finalAudioIdentity: audioIdentities.final
                )
            )
            interviewerUtterances[utteranceIndex].lifecycle = .generating

        case .recordInterviewerSynthesisSpeaking(
            _,
            let utteranceID,
            let attemptID
        ):
            let utteranceIndex = try Self.interviewerUtteranceIndex(
                utteranceID,
                in: interviewerUtterances
            )
            let attemptIndex = try Self.synthesisAttemptIndex(
                attemptID,
                in: interviewerUtterances[utteranceIndex]
            )
            guard interviewerUtterances[utteranceIndex]
                .synthesisAttempts[attemptIndex].lifecycle == .authorized else {
                throw InterviewRoomSessionError.invalidSynthesisTransition(
                    attemptID: attemptID,
                    lifecycle: interviewerUtterances[utteranceIndex]
                        .synthesisAttempts[attemptIndex].lifecycle
                )
            }
            interviewerUtterances[utteranceIndex]
                .synthesisAttempts[attemptIndex].lifecycle = .speaking
            interviewerUtterances[utteranceIndex].lifecycle = .speaking

        case .recordInterviewerSynthesisOutcome(
            _,
            let utteranceID,
            let attemptID,
            let outcome
        ):
            let utteranceIndex = try Self.interviewerUtteranceIndex(
                utteranceID,
                in: interviewerUtterances
            )
            let attemptIndex = try Self.synthesisAttemptIndex(
                attemptID,
                in: interviewerUtterances[utteranceIndex]
            )
            let lifecycle = interviewerUtterances[utteranceIndex]
                .synthesisAttempts[attemptIndex].lifecycle
            guard Self.isActiveSynthesisLifecycle(lifecycle) else {
                throw InterviewRoomSessionError.invalidSynthesisTransition(
                    attemptID: attemptID,
                    lifecycle: lifecycle
                )
            }
            try Self.record(
                synthesisOutcome: outcome,
                utteranceIndex: utteranceIndex,
                attemptIndex: attemptIndex,
                in: &interviewerUtterances
            )

        case .excludeSegment(_, let segmentID, let reason):
            let index = try segmentIndex(segmentID, in: segments)
            guard segments[index].committedTurnID == nil,
                  !Self.isActiveSegment(segments[index]),
                  segments[index].lifecycle != .transcribing else {
                throw InterviewRoomSessionError.invalidSegmentTransition(
                    segmentID: segmentID,
                    lifecycle: segments[index].lifecycle
                )
            }
            segments[index].lifecycle = .excluded
            segments[index].exclusionReason = reason

        case .updateBoardDraft(_, let document):
            guard phase != .completed else {
                throw invalidTransition("updateBoardDraft")
            }
            if board.draft != document {
                endpointGraces = Self.cancellingPendingEndpointGrace(
                    endpointGraces,
                    reason: .boardActivity
                )
            }
            board = BoardWorkspace(
                draft: document,
                revisions: board.revisions,
                selectedRevisionID: board.selectedRevisionID,
                exports: board.exports
            )

        case .saveBoardRevision(let commandID):
            guard phase != .completed else {
                throw invalidTransition("saveBoardRevision")
            }
            let saved = BoardRevision(
                id: Self.boardRevisionID(
                    sessionID: manifest.sessionID,
                    commandID: commandID
                ),
                ordinal: board.revisions.count,
                saveCommandID: commandID,
                document: board.draft
            )
            board = BoardWorkspace(
                draft: board.draft,
                revisions: board.revisions + [saved],
                selectedRevisionID: nil,
                exports: board.exports
            )

        case .selectBoardRevision(_, let revisionID):
            if let revisionID,
               !board.revisions.contains(where: { $0.id == revisionID }) {
                throw InterviewRoomSessionError.boardRevisionNotFound(revisionID)
            }
            board = BoardWorkspace(
                draft: board.draft,
                revisions: board.revisions,
                selectedRevisionID: revisionID,
                exports: board.exports
            )

        case .attachBoardRevision(_, let turnID, let revisionID):
            guard phase != .completed else {
                throw invalidTransition("attachBoardRevision")
            }
            guard board.revisions.contains(where: { $0.id == revisionID }) else {
                throw InterviewRoomSessionError.boardRevisionNotFound(revisionID)
            }
            var turns = manifest.turns
            guard let turnIndex = turns.firstIndex(where: { $0.id == turnID }),
                  case .candidate(let candidate) = turns[turnIndex] else {
                throw InterviewRoomSessionError.boardTurnNotFound(turnID)
            }
            switch candidate.boardAttachment {
            case .noBoard:
                turns[turnIndex] = .candidate(
                    CandidateTurn(
                        id: candidate.id,
                        commandID: candidate.commandID,
                        transcript: candidate.transcript,
                        segmentIDs: candidate.segmentIDs,
                        boardAttachment: .revision(revisionID)
                    )
                )
            case .revision(let existing) where existing == revisionID:
                break
            case .revision:
                throw InterviewRoomSessionError.boardAttachmentImmutable(turnID: turnID)
            }
            return appendingReceipt(
                command: command,
                fingerprint: fingerprint,
                phase: phase,
                turnMode: mode,
                turns: turns,
                segments: segments,
                endpointEvaluations: endpointEvaluations,
                endpointGraces: endpointGraces,
                interviewerUtterances: interviewerUtterances,
                board: board
            )

        case .authorizeBoardExport(let commandID, let revisionID, let settings):
            guard board.revisions.contains(where: { $0.id == revisionID }) else {
                throw InterviewRoomSessionError.boardRevisionNotFound(revisionID)
            }
            let exportID = Self.boardExportID(
                sessionID: manifest.sessionID,
                commandID: commandID
            )
            let identities = try Self.boardArtifactIdentities(exportID: exportID)
            board = BoardWorkspace(
                draft: board.draft,
                revisions: board.revisions,
                selectedRevisionID: board.selectedRevisionID,
                exports: board.exports + [
                    BoardExportOperation(
                        id: exportID,
                        authorizationCommandID: commandID,
                        revisionID: revisionID,
                        settings: settings,
                        artifactIdentities: identities
                    )
                ]
            )

        case .recordBoardExportOutcome(_, let exportID, let outcome):
            guard let exportIndex = board.exports.firstIndex(where: { $0.id == exportID }) else {
                throw InterviewRoomSessionError.boardExportNotFound(exportID)
            }
            let operation = board.exports[exportIndex]
            guard operation.lifecycle == .authorized else {
                throw InterviewRoomSessionError.boardExportAlreadyCompleted(exportID)
            }
            var exports = board.exports
            switch outcome {
            case .ready(let bundle):
                try Self.validateBoardArtifactBundle(
                    bundle,
                    expected: operation.artifactIdentities
                )
                exports[exportIndex] = BoardExportOperation(
                    id: operation.id,
                    authorizationCommandID: operation.authorizationCommandID,
                    revisionID: operation.revisionID,
                    settings: operation.settings,
                    artifactIdentities: operation.artifactIdentities,
                    lifecycle: .ready,
                    bundle: bundle
                )
            case .failed(let failure):
                exports[exportIndex] = BoardExportOperation(
                    id: operation.id,
                    authorizationCommandID: operation.authorizationCommandID,
                    revisionID: operation.revisionID,
                    settings: operation.settings,
                    artifactIdentities: operation.artifactIdentities,
                    lifecycle: .failed,
                    failure: failure
                )
            }
            board = BoardWorkspace(
                draft: board.draft,
                revisions: board.revisions,
                selectedRevisionID: board.selectedRevisionID,
                exports: exports
            )

        case .handOff,
             .handOffWithBoard,
             .handOffSegments,
             .handOffSegmentsWithBoard,
             .completeEndpointGrace,
             .sendAnswer,
             .retryInterviewerResponse:
            preconditionFailure("Provider commands use their durable two-stage paths")

        case .finish:
            guard phase == .ready || phase == .interviewerTurn else {
                throw invalidTransition("finish")
            }
            endpointGraces = Self.cancellingPendingEndpointGrace(
                endpointGraces,
                reason: .sessionFinished
            )
            floorHolds = Self.releasingActiveFloorHold(
                floorHolds,
                commandID: command.commandID,
                reason: .sessionFinished
            )
            phase = .completed
        }

        return appendingReceipt(
            command: command,
            fingerprint: fingerprint,
            phase: phase,
            turnMode: mode,
            turns: manifest.turns,
            segments: segments,
            endpointEvaluations: endpointEvaluations,
            endpointGraces: endpointGraces,
            floorHolds: floorHolds,
            interviewerUtterances: interviewerUtterances,
            board: board,
            candidateNotes: candidateNotes
        )
    }

    private func applyCaptureOutcome(
        _ outcome: SegmentCaptureOutcome,
        to segment: inout CandidateSegment
    ) throws {
        switch outcome {
        case .recordingStarted:
            guard segment.lifecycle == .captureAuthorized else {
                throw InterviewRoomSessionError.invalidSegmentTransition(
                    segmentID: segment.id,
                    lifecycle: segment.lifecycle
                )
            }
            segment.lifecycle = .recording

        case .finalized(let capture):
            guard segment.lifecycle == .finalizationAuthorized,
                  capture.byteCount >= 0,
                  capture.startedAtMilliseconds >= 0,
                  capture.endedAtMilliseconds >= capture.startedAtMilliseconds,
                  capture.durationMilliseconds >= 0,
                  capture.decodedDurationMilliseconds >= 0 else {
                throw InterviewRoomSessionError.invalidCapturedAudio
            }
            segment.capturedAudio = capture
            if capture.isPlayable {
                guard capture.byteCount > 0,
                      capture.decodedDurationMilliseconds > 0 else {
                    throw InterviewRoomSessionError.invalidCapturedAudio
                }
                segment.captureFailureReason = nil
                segment.lifecycle = .audioReady
            } else {
                segment.captureFailureReason = .noPlayableAudio
                segment.lifecycle = .failed
            }

        case .failed(let reason):
            guard segment.lifecycle == .captureAuthorized
                    || segment.lifecycle == .recording
                    || segment.lifecycle == .finalizationAuthorized else {
                throw InterviewRoomSessionError.invalidSegmentTransition(
                    segmentID: segment.id,
                    lifecycle: segment.lifecycle
                )
            }
            segment.captureFailureReason = reason
            segment.lifecycle = .failed
        }
    }

    private func applyTranscriptionOutcome(
        _ outcome: SegmentTranscriptionOutcome,
        attemptID: TranscriptionAttemptID,
        to segment: inout CandidateSegment
    ) throws {
        guard let attemptIndex = segment.transcriptionAttempts.firstIndex(where: {
            $0.id == attemptID
        }) else {
            throw InterviewRoomSessionError.transcriptionAttemptNotFound(attemptID)
        }
        guard segment.lifecycle == .transcribing,
              segment.transcriptionAttempts[attemptIndex].state == .authorized else {
            throw InterviewRoomSessionError.invalidSegmentTransition(
                segmentID: segment.id,
                lifecycle: segment.lifecycle
            )
        }

        switch outcome {
        case .candidate(let result):
            guard !result.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InterviewRoomSessionError.invalidTranscriptionOutcome
            }
            let candidateID = Self.candidateID(attemptID: attemptID)
            let candidate = SegmentTranscriptCandidate(
                id: candidateID,
                attemptID: attemptID,
                body: result.body,
                quality: result.quality,
                integrityReasons: result.integrityReasons
            )
            segment.transcriptCandidates.append(candidate)
            segment.transcriptionAttempts[attemptIndex].state = .candidateStored
            segment.transcriptionAttempts[attemptIndex].candidateID = candidateID
            segment.transcriptionAttempts[attemptIndex].failure = nil
            segment.selectedCandidateID = Self.bestCandidate(
                in: segment.transcriptCandidates
            )?.id
            segment.lifecycle = .transcribed

        case .failed(let failure):
            let attempt = segment.transcriptionAttempts[attemptIndex]
            if let persistedFingerprint = failure.credentialFingerprint,
               persistedFingerprint != attempt.credentialFingerprint {
                throw InterviewRoomSessionError.invalidTranscriptionOutcome
            }
            segment.transcriptionAttempts[attemptIndex].state = .failed
            segment.transcriptionAttempts[attemptIndex].failure = failure
            segment.lifecycle = segment.selectedCandidateID == nil ? .audioReady : .transcribed
        }
    }

    private func handOffSegments(
        commandID: CommandID,
        boardAttachment: CandidateTurnBoardAttachment,
        endpointGraces: [EndpointGrace]? = nil,
        floorHolds: [FloorHold]? = nil,
        fingerprint: String
    ) async throws -> InterviewRoomSnapshot {
        guard manifest.phase == .candidateFloor else {
            throw invalidTransition("handOffSegments")
        }
        guard !manifest.segments.contains(where: Self.isActiveSegment),
              !manifest.segments.contains(where: { $0.lifecycle == .transcribing }) else {
            throw invalidTransition("handOffSegments")
        }

        let selectedSegments = manifest.segments
            .filter {
                $0.committedTurnID == nil
                    && $0.lifecycle != .excluded
                    && $0.selectedCandidate != nil
            }
            .sorted { $0.ordinal < $1.ordinal }
        let excludedSegments = manifest.segments
            .filter { $0.committedTurnID == nil && $0.lifecycle == .excluded }
            .sorted { $0.ordinal < $1.ordinal }
        let unresolved = manifest.segments
            .filter {
                $0.committedTurnID == nil
                    && $0.lifecycle != .excluded
                    && $0.selectedCandidate == nil
            }
            .map(\.id)
        guard unresolved.isEmpty else {
            throw InterviewRoomSessionError.unresolvedSegmentsPreventHandOff(unresolved)
        }
        guard !selectedSegments.isEmpty else {
            throw InterviewRoomSessionError.noTranscribedSegments
        }

        let bodies = selectedSegments.compactMap { segment in
            segment.selectedCandidate?.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard bodies.count == selectedSegments.count,
              bodies.allSatisfy({ !$0.isEmpty }) else {
            throw InterviewRoomSessionError.emptyCandidateTranscript
        }

        let qualities = selectedSegments.compactMap { $0.selectedCandidate?.quality }
        let quality: TranscriptQuality
        if qualities.contains(.possibleContamination) {
            quality = .possibleContamination
        } else if qualities.contains(.bestAvailable) {
            quality = .bestAvailable
        } else {
            quality = .verified
        }

        return try await handOff(
            commandID: commandID,
            transcript: CandidateTranscript(
                body: bodies.joined(separator: "\n\n"),
                quality: quality
            ),
            segmentIDs: (selectedSegments + excludedSegments)
                .sorted { $0.ordinal < $1.ordinal }
                .map(\.id),
            boardAttachment: boardAttachment,
            endpointGraces: endpointGraces,
            floorHolds: floorHolds,
            fingerprint: fingerprint
        )
    }

    private func completeEndpointGrace(
        commandID: CommandID,
        graceID: EndpointGraceID,
        boardAttachment: CandidateTurnBoardAttachment,
        fingerprint: String
    ) async throws -> InterviewRoomSnapshot {
        guard manifest.phase == .candidateFloor,
              manifest.turnMode.usesAutomaticEndpointCompletion,
              manifest.floorHolds.activeHold == nil,
              let graceIndex = manifest.endpointGraces.firstIndex(where: {
                  $0.id == graceID
              }) else {
            throw InterviewRoomSessionError.endpointGraceNotFound(graceID)
        }
        let grace = manifest.endpointGraces[graceIndex]
        guard grace.lifecycle == .pending else {
            throw InterviewRoomSessionError.invalidEndpointGraceTransition(
                graceID: graceID,
                lifecycle: grace.lifecycle
            )
        }
        guard let evaluation = manifest.endpointEvaluations.first(where: {
            $0.id == grace.evaluationID
        }),
        evaluation.lifecycle == .proposalStored,
        evaluation.proposal?.decision == .likelyEnd,
        evaluation.selectedCandidateIDs == grace.selectedCandidateIDs,
        Self.isCurrentEndpointEvaluation(
            evaluation,
            phase: manifest.phase,
            mode: manifest.turnMode,
            turns: manifest.turns,
            segments: manifest.segments
        ) else {
            throw InterviewRoomSessionError.endpointGraceEvidenceMismatch
        }

        let candidateTurnID = Self.turnID(
            sessionID: manifest.sessionID,
            commandID: commandID,
            role: "candidate"
        )
        var completedGraces = manifest.endpointGraces
        completedGraces[graceIndex] = grace.completing(
            candidateTurnID: candidateTurnID
        )
        return try await handOffSegments(
            commandID: commandID,
            boardAttachment: boardAttachment,
            endpointGraces: completedGraces,
            fingerprint: fingerprint
        )
    }

    private func sendAnswer(
        commandID: CommandID,
        boardAttachment: CandidateTurnBoardAttachment,
        fingerprint: String
    ) async throws -> InterviewRoomSnapshot {
        guard manifest.phase == .candidateFloor,
              manifest.turnMode == .continuousConversation,
              let holdIndex = manifest.floorHolds.lastIndex(where: {
                  $0.lifecycle == .active
              }) else {
            throw InterviewRoomSessionError.floorHoldNotActive
        }

        let candidateTurnID = Self.turnID(
            sessionID: manifest.sessionID,
            commandID: commandID,
            role: "candidate"
        )
        var releasedHolds = manifest.floorHolds
        releasedHolds[holdIndex] = releasedHolds[holdIndex].releasing(
            commandID: commandID,
            reason: .sendAnswer,
            candidateTurnID: candidateTurnID
        )
        return try await handOffSegments(
            commandID: commandID,
            boardAttachment: boardAttachment,
            endpointGraces: Self.cancellingPendingEndpointGrace(
                manifest.endpointGraces,
                reason: .floorHold
            ),
            floorHolds: releasedHolds,
            fingerprint: fingerprint
        )
    }

    /// Hand off is deliberately two durable transitions. The Candidate Turn
    /// and its Segment associations are saved before provider work starts.
    private func handOff(
        commandID: CommandID,
        transcript: CandidateTranscript,
        segmentIDs: [SegmentID],
        boardAttachment: CandidateTurnBoardAttachment,
        endpointGraces: [EndpointGrace]? = nil,
        floorHolds: [FloorHold]? = nil,
        fingerprint: String
    ) async throws -> InterviewRoomSnapshot {
        guard manifest.phase == .candidateFloor else {
            throw invalidTransition(segmentIDs.isEmpty ? "handOff" : "handOffSegments")
        }
        let nextFloorHolds = floorHolds ?? manifest.floorHolds
        if nextFloorHolds.activeHold != nil {
            throw InterviewRoomSessionError.floorHoldActive
        }
        guard !transcript.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterviewRoomSessionError.emptyCandidateTranscript
        }
        guard transcript.body.utf8.count <= CandidateTranscript.maximumBodyUTF8Bytes else {
            throw InterviewRoomSessionError.candidateTranscriptTooLong(
                maximumUTF8Bytes: CandidateTranscript.maximumBodyUTF8Bytes
            )
        }
        if segmentIDs.isEmpty,
           manifest.segments.contains(where: { $0.committedTurnID == nil }) {
            throw InterviewRoomSessionError.uncommittedSegmentsRequireSegmentHandOff
        }
        try validateBoardAttachment(boardAttachment, in: manifest.board)

        let candidate = CandidateTurn(
            id: Self.turnID(
                sessionID: manifest.sessionID,
                commandID: commandID,
                role: "candidate"
            ),
            commandID: commandID,
            transcript: transcript,
            segmentIDs: segmentIDs,
            boardAttachment: boardAttachment
        )
        var segments = manifest.segments
        for segmentID in segmentIDs {
            let index = try segmentIndex(segmentID, in: segments)
            guard segments[index].committedTurnID == nil else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "segment cannot be committed twice"
                )
            }
            segments[index].committedTurnID = candidate.id
        }

        let candidateRevision = manifest.revision + 1
        let receipt = AppliedCommandRecord(
            commandID: commandID,
            payloadFingerprint: fingerprint,
            resultingRevision: candidateRevision
        )
        let awaitingResponse = SessionManifest(
            sessionID: manifest.sessionID,
            activityID: manifest.activityID,
            activityPrompt: manifest.activityPrompt,
            phase: .interviewerProcessing,
            turnMode: manifest.turnMode,
            turns: manifest.turns + [.candidate(candidate)],
            segments: segments,
            endpointEvaluations: manifest.endpointEvaluations,
            endpointGraces: endpointGraces ?? manifest.endpointGraces,
            floorHolds: nextFloorHolds,
            interviewerUtterances: manifest.interviewerUtterances,
            board: manifest.board,
            candidateNotes: manifest.candidateNotes,
            revision: candidateRevision,
            appliedCommands: manifest.appliedCommands + [receipt]
        )
        try await persist(awaitingResponse)

        return try await completeInterviewerResponse(for: candidate)
    }

    private func retryInterviewerResponse(
        commandID: CommandID,
        fingerprint: String
    ) async throws -> InterviewRoomSnapshot {
        guard manifest.phase == .interviewerProcessing,
              case .candidate(let candidate) = manifest.turns.last else {
            throw invalidTransition("retryInterviewerResponse")
        }
        let receipt = AppliedCommandRecord(
            commandID: commandID,
            payloadFingerprint: fingerprint,
            resultingRevision: manifest.revision + 1
        )
        let pendingRetry = SessionManifest(
            sessionID: manifest.sessionID,
            activityID: manifest.activityID,
            activityPrompt: manifest.activityPrompt,
            phase: .interviewerProcessing,
            turnMode: manifest.turnMode,
            turns: manifest.turns,
            segments: manifest.segments,
            endpointEvaluations: manifest.endpointEvaluations,
            endpointGraces: manifest.endpointGraces,
            floorHolds: manifest.floorHolds,
            interviewerUtterances: manifest.interviewerUtterances,
            board: manifest.board,
            candidateNotes: manifest.candidateNotes,
            revision: manifest.revision + 1,
            appliedCommands: manifest.appliedCommands + [receipt]
        )
        try await persist(pendingRetry)

        return try await completeInterviewerResponse(for: candidate)
    }

    private func completeInterviewerResponse(
        for candidate: CandidateTurn
    ) async throws -> InterviewRoomSnapshot {
        let responseTurnID = Self.turnID(
            sessionID: manifest.sessionID,
            commandID: candidate.commandID,
            role: "interviewer"
        )
        let request = InterviewerRequest(
            sessionID: manifest.sessionID,
            activityID: manifest.activityID,
            activityPrompt: manifest.activityPrompt,
            candidateTurn: candidate,
            priorVisibleTurns: Self.boundedPriorVisibleTurns(
                Array(manifest.turns.dropLast())
            ),
            responseTurnID: responseTurnID
        )
        let response = try await interviewerRuntime.respond(to: request)
        guard !response.displayMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.displayMarkdown.utf8.count
                <= CanonicalInterviewerResponse.maximumDisplayMarkdownUTF8Bytes,
              response.spokenText.utf8.count
                <= CanonicalInterviewerResponse.maximumSpokenTextUTF8Bytes else {
            throw InterviewRoomSessionError.invalidInterviewerResponse
        }

        let interviewer = InterviewerTurn(
            id: responseTurnID,
            commandID: candidate.commandID,
            replyToTurnID: candidate.id,
            response: response
        )
        let utterance = Self.makeInterviewerUtterance(
            sessionID: manifest.sessionID,
            turn: interviewer
        )
        let completed = SessionManifest(
            sessionID: manifest.sessionID,
            activityID: manifest.activityID,
            activityPrompt: manifest.activityPrompt,
            phase: .interviewerTurn,
            turnMode: manifest.turnMode,
            turns: manifest.turns + [.interviewer(interviewer)],
            segments: manifest.segments,
            endpointEvaluations: manifest.endpointEvaluations,
            endpointGraces: manifest.endpointGraces,
            floorHolds: manifest.floorHolds,
            interviewerUtterances: manifest.interviewerUtterances + [utterance],
            board: manifest.board,
            candidateNotes: manifest.candidateNotes,
            revision: manifest.revision + 1,
            appliedCommands: manifest.appliedCommands
        )
        try await persist(completed)
        return InterviewRoomSnapshot(manifest: completed)
    }

    private func appendingReceipt(
        command: InterviewRoomCommand,
        fingerprint: String,
        phase: InterviewRoomPhase,
        turnMode: TurnMode,
        turns: [InterviewTurn],
        segments: [CandidateSegment],
        endpointEvaluations: [EndpointEvaluation],
        endpointGraces: [EndpointGrace]? = nil,
        floorHolds: [FloorHold]? = nil,
        interviewerUtterances: [InterviewerUtterance]? = nil,
        board: BoardWorkspace? = nil,
        candidateNotes: CandidateNotes? = nil
    ) -> SessionManifest {
        let nextRevision = manifest.revision + 1
        let applied = AppliedCommandRecord(
            commandID: command.commandID,
            payloadFingerprint: fingerprint,
            resultingRevision: nextRevision
        )
        return SessionManifest(
            sessionID: manifest.sessionID,
            activityID: manifest.activityID,
            activityPrompt: manifest.activityPrompt,
            phase: phase,
            turnMode: turnMode,
            turns: turns,
            segments: segments,
            endpointEvaluations: endpointEvaluations,
            endpointGraces: endpointGraces ?? manifest.endpointGraces,
            floorHolds: floorHolds ?? manifest.floorHolds,
            interviewerUtterances: interviewerUtterances ?? manifest.interviewerUtterances,
            board: board ?? manifest.board,
            candidateNotes: candidateNotes ?? manifest.candidateNotes,
            revision: nextRevision,
            appliedCommands: manifest.appliedCommands + [applied]
        )
    }

    private func persist(_ next: SessionManifest) async throws {
        try await manifestStore.save(next, expectedRevision: manifest.revision)
        manifest = next
    }

    private func segmentIndex(
        _ segmentID: SegmentID,
        in segments: [CandidateSegment]
    ) throws -> Int {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else {
            throw InterviewRoomSessionError.segmentNotFound(segmentID)
        }
        return index
    }

    private func endpointEvaluationIndex(
        _ evaluationID: EndpointEvaluationID,
        in evaluations: [EndpointEvaluation]
    ) throws -> Int {
        guard let index = evaluations.firstIndex(where: { $0.id == evaluationID }) else {
            throw InterviewRoomSessionError.endpointEvaluationNotFound(evaluationID)
        }
        return index
    }

    private func endpointGraceIndex(
        _ graceID: EndpointGraceID,
        in graces: [EndpointGrace]
    ) throws -> Int {
        guard let index = graces.firstIndex(where: { $0.id == graceID }) else {
            throw InterviewRoomSessionError.endpointGraceNotFound(graceID)
        }
        return index
    }

    private static func cancellingPendingEndpointGrace(
        _ graces: [EndpointGrace],
        reason: EndpointGraceCancellationReason
    ) -> [EndpointGrace] {
        guard let index = graces.firstIndex(where: { $0.lifecycle == .pending }) else {
            return graces
        }
        var updated = graces
        updated[index] = updated[index].cancelling(reason: reason)
        return updated
    }

    private static func releasingActiveFloorHold(
        _ holds: [FloorHold],
        commandID: CommandID,
        reason: FloorHoldReleaseReason
    ) -> [FloorHold] {
        guard let index = holds.lastIndex(where: { $0.lifecycle == .active }) else {
            return holds
        }
        var updated = holds
        updated[index] = updated[index].releasing(
            commandID: commandID,
            reason: reason
        )
        return updated
    }

    private static func interviewerUtteranceIndex(
        _ utteranceID: InterviewerUtteranceID,
        in utterances: [InterviewerUtterance]
    ) throws -> Int {
        guard let index = utterances.firstIndex(where: { $0.id == utteranceID }) else {
            throw InterviewRoomSessionError.interviewerUtteranceNotFound(utteranceID)
        }
        return index
    }

    private static func synthesisAttemptIndex(
        _ attemptID: SynthesisAttemptID,
        in utterance: InterviewerUtterance
    ) throws -> Int {
        guard let index = utterance.synthesisAttempts.firstIndex(where: {
            $0.id == attemptID
        }) else {
            throw InterviewRoomSessionError.synthesisAttemptNotFound(attemptID)
        }
        return index
    }

    private static func isActiveSynthesisAttempt(_ attempt: SynthesisAttempt) -> Bool {
        isActiveSynthesisLifecycle(attempt.lifecycle)
    }

    private static func isActiveSynthesisLifecycle(
        _ lifecycle: SynthesisAttemptLifecycle
    ) -> Bool {
        lifecycle == .authorized || lifecycle == .speaking
    }

    private static func record(
        synthesisOutcome: InterviewerSynthesisOutcome,
        utteranceIndex: Int,
        attemptIndex: Int,
        in utterances: inout [InterviewerUtterance]
    ) throws {
        switch synthesisOutcome {
        case .ready(let audio):
            let attempt = utterances[utteranceIndex].synthesisAttempts[attemptIndex]
            try validateSynthesisAudio(audio, expectedIdentity: attempt.finalAudioIdentity)
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].lifecycle = .ready
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].audio = audio
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].failure = nil
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].stopReason = nil
            utterances[utteranceIndex].selectedAttemptID = attempt.id
            utterances[utteranceIndex].lifecycle = .ready

        case .stopped(let reason):
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].lifecycle = .stopped
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].audio = nil
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].failure = nil
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].stopReason = reason
            utterances[utteranceIndex].lifecycle =
                utterances[utteranceIndex].selectedAttemptID == nil ? .stopped : .ready

        case .failed(let failure):
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].lifecycle = .failed
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].audio = nil
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].failure = failure
            utterances[utteranceIndex].synthesisAttempts[attemptIndex].stopReason = nil
            utterances[utteranceIndex].lifecycle =
                utterances[utteranceIndex].selectedAttemptID == nil ? .failed : .ready
        }
    }

    private static func validateSpeechProvenance(
        _ provenance: InterviewerSpeechProvenance
    ) throws {
        let values = [
            provenance.providerID,
            provenance.modelID,
            provenance.modelRevision,
        ]
        guard values.allSatisfy({
            !$0.isEmpty
                && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                && $0.utf8.count <= 512
                && $0.unicodeScalars.allSatisfy({ scalar in
                    !CharacterSet.controlCharacters.contains(scalar)
                })
        }), provenance.profile.hasValidFingerprint() else {
            throw InterviewRoomSessionError.invalidSpeechProvenance
        }
    }

    private static func validateSynthesisAudio(
        _ audio: InterviewerSpeechAudioArtifact,
        expectedIdentity: InterviewerAudioIdentity
    ) throws {
        guard audio.isValidFinalAudio(expectedIdentity: expectedIdentity) else {
            throw InterviewRoomSessionError.invalidSynthesisAudio
        }
    }

    private static func makeInterviewerUtterance(
        sessionID: SessionID,
        turn: InterviewerTurn
    ) -> InterviewerUtterance {
        InterviewerUtterance(
            id: interviewerUtteranceID(sessionID: sessionID, turnID: turn.id),
            turnID: turn.id,
            spokenTextFingerprint: digest(
                Data(turn.spokenText.utf8),
                namespace: "interviewer-spoken-text"
            )
        )
    }

    private static func currentEndpointCandidateIDs(
        in segments: [CandidateSegment]
    ) throws -> [TranscriptCandidateID] {
        let draftSegments = segments
            .filter { $0.committedTurnID == nil && $0.lifecycle != .excluded }
            .sorted { $0.ordinal < $1.ordinal }
        guard !draftSegments.isEmpty,
              draftSegments.allSatisfy({
                  !isActiveSegment($0)
                      && $0.lifecycle != .transcribing
                      && $0.selectedCandidateID != nil
              }) else {
            throw InterviewRoomSessionError.endpointEvidenceMismatch
        }
        return draftSegments.compactMap(\.selectedCandidateID)
    }

    private static func latestInterviewerTurnID(
        in turns: [InterviewTurn]
    ) -> TurnID? {
        for turn in turns.reversed() {
            if case .interviewer(let interviewer) = turn {
                return interviewer.id
            }
        }
        return nil
    }

    /// Revalidates the durable authorization against the exact current draft
    /// immediately before a classifier proposal becomes canonical evaluation
    /// state. This check stays in the Session Module so phase, evidence, and
    /// question identity are observed atomically with outcome persistence.
    private static func isCurrentEndpointEvaluation(
        _ evaluation: EndpointEvaluation,
        phase: InterviewRoomPhase,
        mode: TurnMode,
        turns: [InterviewTurn],
        segments: [CandidateSegment]
    ) -> Bool {
        guard phase == .candidateFloor,
              mode.usesAutomaticEndpointCompletion,
              (try? validateEndpointContextFingerprint(evaluation.contextFingerprint)) != nil,
              latestInterviewerTurnID(in: turns) == evaluation.questionTurnID,
              let currentCandidateIDs = try? currentEndpointCandidateIDs(in: segments),
              currentCandidateIDs == evaluation.selectedCandidateIDs,
              let triggerSegment = segments.first(where: {
                  $0.id == evaluation.triggerSegmentID
              }),
              triggerSegment.committedTurnID == nil,
              triggerSegment.lifecycle != .excluded,
              let triggerCandidateID = triggerSegment.selectedCandidateID,
              evaluation.selectedCandidateIDs.contains(triggerCandidateID) else {
            return false
        }
        return true
    }

    private static func recordingEndpointOutcome(
        _ outcome: EndpointEvaluationOutcome,
        for evaluation: EndpointEvaluation
    ) -> EndpointEvaluation {
        switch outcome {
        case .proposal(let proposal):
            return EndpointEvaluation(
                id: evaluation.id,
                authorizationCommandID: evaluation.authorizationCommandID,
                triggerSegmentID: evaluation.triggerSegmentID,
                selectedCandidateIDs: evaluation.selectedCandidateIDs,
                questionTurnID: evaluation.questionTurnID,
                contextFingerprint: evaluation.contextFingerprint,
                lifecycle: .proposalStored,
                proposal: proposal
            )
        case .failed(let failure):
            return EndpointEvaluation(
                id: evaluation.id,
                authorizationCommandID: evaluation.authorizationCommandID,
                triggerSegmentID: evaluation.triggerSegmentID,
                selectedCandidateIDs: evaluation.selectedCandidateIDs,
                questionTurnID: evaluation.questionTurnID,
                contextFingerprint: evaluation.contextFingerprint,
                lifecycle: .failed,
                failure: failure
            )
        }
    }

    private static func validateEndpointEvaluationOutcome(
        _ outcome: EndpointEvaluationOutcome
    ) throws {
        switch outcome {
        case .proposal(let proposal):
            let isConsistent: Bool
            switch proposal.reasonCode {
            case .explicitHandoffCue, .answerResolvesQuestion:
                isConsistent = proposal.decision == .likelyEnd
            case .unfinishedThought, .requestedPartUnanswered, .recentWorkspaceActivity:
                isConsistent = proposal.decision == .likelyContinue
            case .insufficientEvidence:
                isConsistent = proposal.decision == .ambiguous
            }
            guard isConsistent else {
                throw InterviewRoomSessionError.invalidEndpointEvaluationOutcome
            }

        case .failed(let failure):
            if let statusCode = failure.providerStatusCode {
                guard failure.reason == .providerRejected,
                      (100...599).contains(statusCode) else {
                    throw InterviewRoomSessionError.invalidEndpointEvaluationOutcome
                }
            }
        }
    }

    private func invalidTransition(_ command: String) -> InterviewRoomSessionError {
        .invalidTransition(command: command, phase: manifest.phase)
    }

    private static func isActiveSegment(_ segment: CandidateSegment) -> Bool {
        segment.lifecycle == .captureAuthorized
            || segment.lifecycle == .recording
            || segment.lifecycle == .finalizationAuthorized
    }

    /// Returns a contiguous recent suffix so the runtime receives bounded,
    /// canonical visible history without truncating any individual Turn.
    private static func boundedPriorVisibleTurns(
        _ turns: [InterviewTurn]
    ) -> [InterviewTurn] {
        let maximumTurnCount = InterviewerRequest.maximumPriorVisibleTurns
            - InterviewerRequest.maximumPriorVisibleTurns % 2
        let maximumByteCount = InterviewerRequest.maximumPriorVisibleHistoryUTF8Bytes
        var selectedReversed: [InterviewTurn] = []
        var selectedByteCount = 0
        var pairEnd = turns.endIndex

        while pairEnd >= 2, selectedReversed.count + 2 <= maximumTurnCount {
            let candidateIndex = turns.index(pairEnd, offsetBy: -2)
            let interviewerIndex = turns.index(before: pairEnd)
            guard case .candidate(let candidate) = turns[candidateIndex],
                  case .interviewer(let interviewer) = turns[interviewerIndex] else {
                break
            }

            let pairByteCount = candidate.transcript.body.utf8.count
                + interviewer.displayMarkdown.utf8.count
                + interviewer.spokenText.utf8.count
            guard pairByteCount <= maximumByteCount - selectedByteCount else {
                break
            }

            selectedReversed.append(turns[interviewerIndex])
            selectedReversed.append(turns[candidateIndex])
            selectedByteCount += pairByteCount
            pairEnd = candidateIndex
        }

        return Array(selectedReversed.reversed())
    }

    private static func bestCandidate(
        in candidates: [SegmentTranscriptCandidate]
    ) -> SegmentTranscriptCandidate? {
        var best: SegmentTranscriptCandidate?
        for candidate in candidates {
            guard let current = best else {
                best = candidate
                continue
            }
            if isBetter(candidate, than: current) {
                best = candidate
            }
        }
        return best
    }

    private static func isBetter(
        _ candidate: SegmentTranscriptCandidate,
        than current: SegmentTranscriptCandidate
    ) -> Bool {
        let candidateScore = transcriptScore(candidate)
        let currentScore = transcriptScore(current)
        if candidateScore.quality != currentScore.quality {
            return candidateScore.quality > currentScore.quality
        }
        if candidateScore.words != currentScore.words {
            return candidateScore.words > currentScore.words
        }
        if candidateScore.characters != currentScore.characters {
            return candidateScore.characters > currentScore.characters
        }
        return false
    }

    private static func transcriptScore(
        _ candidate: SegmentTranscriptCandidate
    ) -> (quality: Int, words: Int, characters: Int) {
        let quality: Int
        switch candidate.quality {
        case .verified: quality = 3
        case .bestAvailable: quality = 2
        case .possibleContamination: quality = 1
        }
        let normalized = candidate.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            quality,
            normalized.split(whereSeparator: { $0.isWhitespace }).count,
            normalized.count
        )
    }

    private static func fingerprint(for command: InterviewRoomCommand) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedCommand: Data
        do {
            encodedCommand = try encoder.encode(command)
        } catch {
            throw InterviewRoomSessionError.commandEncodingFailed
        }
        var versionedPayload = Data("interview-room-command:v1\n".utf8)
        versionedPayload.append(encodedCommand)
        return digest(versionedPayload, namespace: "command")
    }

    /// Stable identity for the exact classifier request and its durable
    /// evidence references. Candidate identity is deliberately part of the
    /// envelope: a newly selected candidate may contain byte-identical text
    /// while still representing a distinct authorized evaluation.
    public static func endpointContextFingerprint(
        _ context: SemanticEndpointContext,
        triggerSegmentID: SegmentID,
        selectedCandidateIDs: [TranscriptCandidateID],
        questionTurnID: TurnID?
    ) throws -> String {
        let envelope = EndpointContextFingerprintEnvelope(
            context: context,
            triggerSegmentID: triggerSegmentID,
            selectedCandidateIDs: selectedCandidateIDs,
            questionTurnID: questionTurnID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return digest(
                try encoder.encode(envelope),
                namespace: "semantic-endpoint-context"
            )
        } catch {
            throw InterviewRoomSessionError.endpointContextEncodingFailed
        }
    }

    static func credentialFingerprint(_ credential: String) -> String {
        digest(Data(credential.utf8), namespace: "groq-credential")
    }

    static func derivedCommandID(
        source: CommandID,
        operation: String
    ) -> CommandID {
        CommandID(stableIdentity(
            namespace: "derived-command",
            fields: [source.rawValue, operation]
        ))
    }

    private static func segmentID(
        sessionID: SessionID,
        commandID: CommandID
    ) -> SegmentID {
        SegmentID(stableIdentity(
            namespace: "segment",
            fields: [sessionID.rawValue, commandID.rawValue]
        ))
    }

    private static func segmentFileName(segmentID: SegmentID) -> String {
        let suffix = segmentID.rawValue.split(separator: ":").last.map(String.init)
            ?? segmentID.rawValue
        return "segment-\(suffix).m4a"
    }

    private static func attemptID(
        sessionID: SessionID,
        segmentID: SegmentID,
        commandID: CommandID
    ) -> TranscriptionAttemptID {
        TranscriptionAttemptID(stableIdentity(
            namespace: "transcription-attempt",
            fields: [sessionID.rawValue, segmentID.rawValue, commandID.rawValue]
        ))
    }

    private static func candidateID(
        attemptID: TranscriptionAttemptID
    ) -> TranscriptCandidateID {
        TranscriptCandidateID(stableIdentity(
            namespace: "transcript-candidate",
            fields: [attemptID.rawValue]
        ))
    }

    private static func endpointEvaluationID(
        sessionID: SessionID,
        commandID: CommandID
    ) -> EndpointEvaluationID {
        EndpointEvaluationID(stableIdentity(
            namespace: "endpoint-evaluation",
            fields: [sessionID.rawValue, commandID.rawValue]
        ))
    }

    private static func endpointGraceID(
        sessionID: SessionID,
        commandID: CommandID
    ) -> EndpointGraceID {
        EndpointGraceID(stableIdentity(
            namespace: "endpoint-grace",
            fields: [sessionID.rawValue, commandID.rawValue]
        ))
    }

    private static func floorHoldID(
        sessionID: SessionID,
        commandID: CommandID
    ) -> FloorHoldID {
        FloorHoldID(stableIdentity(
            namespace: "floor-hold",
            fields: [sessionID.rawValue, commandID.rawValue]
        ))
    }

    private static func boardRevisionID(
        sessionID: SessionID,
        commandID: CommandID
    ) -> BoardRevisionID {
        BoardRevisionID(stableIdentity(
            namespace: "board-revision",
            fields: [sessionID.rawValue, commandID.rawValue]
        ))
    }

    private static func boardExportID(
        sessionID: SessionID,
        commandID: CommandID
    ) -> BoardExportID {
        BoardExportID(stableIdentity(
            namespace: "board-export",
            fields: [sessionID.rawValue, commandID.rawValue]
        ))
    }

    private static func boardArtifactIdentities(
        exportID: BoardExportID
    ) throws -> BoardArtifactIdentities {
        let suffix = hexDigest(Data(exportID.rawValue.utf8))
        let exportDirectory = "BoardArtifacts/board-\(suffix)"
        return BoardArtifactIdentities(
            source: try BoardArtifactIdentity(
                validating: "\(exportDirectory)/board.drawio"
            ),
            svg: try BoardArtifactIdentity(
                validating: "\(exportDirectory)/board.svg"
            ),
            png: try BoardArtifactIdentity(
                validating: "\(exportDirectory)/board.png"
            )
        )
    }

    private func validateBoardAttachment(
        _ attachment: CandidateTurnBoardAttachment,
        in board: BoardWorkspace
    ) throws {
        guard case .revision(let revisionID) = attachment else { return }
        guard board.revisions.contains(where: { $0.id == revisionID }) else {
            throw InterviewRoomSessionError.boardRevisionNotFound(revisionID)
        }
    }

    private static func validateBoardArtifactBundle(
        _ bundle: BoardArtifactBundle,
        expected: BoardArtifactIdentities
    ) throws {
        let values: [(BoardArtifactMetadata, BoardArtifactIdentity, Int)] = [
            (bundle.source, expected.source, 4 * 1_024 * 1_024),
            (bundle.svg, expected.svg, 16 * 1_024 * 1_024),
            (bundle.png, expected.png, 64 * 1_024 * 1_024),
        ]
        guard values.allSatisfy({ metadata, expectedIdentity, maximumBytes in
            metadata.identity == expectedIdentity
                && metadata.byteCount > 0
                && metadata.byteCount <= maximumBytes
                && metadata.sha256.count == 64
                && metadata.sha256.allSatisfy({
                    ("0"..."9").contains($0) || ("a"..."f").contains($0)
                })
        }) else {
            throw InterviewRoomSessionError.invalidBoardExportBundle
        }
    }

    private static func turnID(
        sessionID: SessionID,
        commandID: CommandID,
        role: String
    ) -> TurnID {
        TurnID(stableIdentity(
            namespace: "turn",
            fields: [sessionID.rawValue, commandID.rawValue, role]
        ))
    }

    private static func interviewerUtteranceID(
        sessionID: SessionID,
        turnID: TurnID
    ) -> InterviewerUtteranceID {
        InterviewerUtteranceID(stableIdentity(
            namespace: "interviewer-utterance",
            fields: [sessionID.rawValue, turnID.rawValue]
        ))
    }

    private static func synthesisAttemptID(
        sessionID: SessionID,
        utteranceID: InterviewerUtteranceID,
        commandID: CommandID
    ) -> SynthesisAttemptID {
        SynthesisAttemptID(stableIdentity(
            namespace: "synthesis-attempt",
            fields: [sessionID.rawValue, utteranceID.rawValue, commandID.rawValue]
        ))
    }

    private static func synthesisAudioIdentities(
        attemptID: SynthesisAttemptID
    ) throws -> (partial: InterviewerAudioIdentity, final: InterviewerAudioIdentity) {
        let attemptDigest = hexDigest(Data(attemptID.rawValue.utf8))
        return (
            try InterviewerAudioIdentity(
                validating: "speech-\(attemptDigest).partial.wav"
            ),
            try InterviewerAudioIdentity(validating: "speech-\(attemptDigest).wav")
        )
    }

    private static func stableIdentity(
        namespace: String,
        fields: [String]
    ) -> String {
        var tuple = Data()
        for field in ["interview-arc-live", namespace, "v1"] + fields {
            appendLengthPrefixed(field, to: &tuple)
        }
        return "\(namespace):sha256:v1:\(hexDigest(tuple))"
    }

    private static func digest(_ data: Data, namespace: String) -> String {
        var versioned = Data()
        appendLengthPrefixed("interview-arc-live", to: &versioned)
        appendLengthPrefixed(namespace, to: &versioned)
        appendLengthPrefixed("v1", to: &versioned)
        versioned.append(data)
        return "sha256:v1:\(hexDigest(versioned))"
    }

    private static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        let count = UInt64(bytes.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((count >> UInt64(shift)) & 0xff))
        }
        data.append(bytes)
    }

    private static func validateIdentifier(_ value: String, name: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterviewRoomSessionError.emptyIdentifier(name: name)
        }
    }

    private static func validateCredentialFingerprint(_ value: String) throws {
        let prefix = "sha256:v1:"
        let suffix = value.dropFirst(prefix.count)
        guard value.hasPrefix(prefix),
              suffix.count == 64,
              suffix.allSatisfy({ $0.isHexDigit }) else {
            throw InterviewRoomSessionError.invalidCredentialFingerprint
        }
    }

    private static func validateEndpointContextFingerprint(_ value: String) throws {
        let prefix = "sha256:v1:"
        let suffix = value.dropFirst(prefix.count)
        guard value.hasPrefix(prefix),
              suffix.count == 64,
              suffix.allSatisfy({ $0.isHexDigit }) else {
            throw InterviewRoomSessionError.invalidEndpointContextFingerprint
        }
    }

    private static func validateBoardWorkspace(
        _ board: BoardWorkspace,
        sessionID: SessionID,
        appliedCommandIDs: Set<CommandID>,
        candidateTurns: [CandidateTurn]
    ) throws {
        let revisionIDs = board.revisions.map(\.id)
        guard Set(revisionIDs).count == revisionIDs.count,
              board.revisions.enumerated().allSatisfy({ index, revision in
                  revision.ordinal == index
                      && revision.id == boardRevisionID(
                          sessionID: sessionID,
                          commandID: revision.saveCommandID
                      )
                      && appliedCommandIDs.contains(revision.saveCommandID)
              }),
              board.selectedRevisionID.map(Set(revisionIDs).contains) ?? true else {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "invalid Board Revision history"
            )
        }

        let knownRevisions = Set(revisionIDs)
        for candidate in candidateTurns {
            if case .revision(let revisionID) = candidate.boardAttachment,
               !knownRevisions.contains(revisionID) {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "Candidate Turn references a missing Board Revision"
                )
            }
        }

        let exportIDs = board.exports.map(\.id)
        let exportCommandIDs = board.exports.map(\.authorizationCommandID)
        guard Set(exportIDs).count == exportIDs.count,
              Set(exportCommandIDs).count == exportCommandIDs.count else {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "invalid Board Export identity history"
            )
        }

        for operation in board.exports {
            let expectedID = boardExportID(
                sessionID: sessionID,
                commandID: operation.authorizationCommandID
            )
            let expectedIdentities: BoardArtifactIdentities
            do {
                expectedIdentities = try boardArtifactIdentities(exportID: expectedID)
            } catch {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "invalid Board Export artifact identities"
                )
            }
            guard operation.id == expectedID,
                  operation.artifactIdentities == expectedIdentities,
                  appliedCommandIDs.contains(operation.authorizationCommandID),
                  knownRevisions.contains(operation.revisionID) else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "Board Export authorization is inconsistent"
                )
            }

            switch operation.lifecycle {
            case .authorized:
                guard operation.bundle == nil, operation.failure == nil else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "authorized Board Export already has an outcome"
                    )
                }
            case .ready:
                guard let bundle = operation.bundle, operation.failure == nil else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "ready Board Export has no complete bundle"
                    )
                }
                do {
                    try validateBoardArtifactBundle(bundle, expected: expectedIdentities)
                } catch {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "ready Board Export bundle is invalid"
                    )
                }
            case .failed:
                guard operation.bundle == nil, operation.failure != nil else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "failed Board Export outcome is incomplete"
                    )
                }
            }
        }
    }

    private static func validate(_ manifest: SessionManifest) throws {
        try validateIdentifier(manifest.sessionID.rawValue, name: "sessionID")
        try validateIdentifier(manifest.activityID, name: "activityID")
        guard manifest.revision >= 0 else {
            throw InterviewRoomSessionError.invalidManifest(reason: "negative revision")
        }

        var index = 0
        while index + 1 < manifest.turns.count {
            guard case .candidate(let candidate) = manifest.turns[index],
                  case .interviewer(let interviewer) = manifest.turns[index + 1],
                  interviewer.replyToTurnID == candidate.id,
                  interviewer.commandID == candidate.commandID,
                  !candidate.transcript.body
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  candidate.transcript.body.utf8.count
                    <= CandidateTranscript.maximumBodyUTF8Bytes,
                  !interviewer.displayMarkdown
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  interviewer.displayMarkdown.utf8.count
                    <= CanonicalInterviewerResponse.maximumDisplayMarkdownUTF8Bytes,
                  !interviewer.spokenText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  interviewer.spokenText.utf8.count
                    <= CanonicalInterviewerResponse.maximumSpokenTextUTF8Bytes else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "turns must be ordered candidate then matching interviewer"
                )
            }
            index += 2
        }

        if index < manifest.turns.count {
            guard manifest.phase == .interviewerProcessing,
                  index == manifest.turns.count - 1,
                  case .candidate(let candidate) = manifest.turns[index],
                  !candidate.transcript.body
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  candidate.transcript.body.utf8.count
                    <= CandidateTranscript.maximumBodyUTF8Bytes else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "only an interviewer-processing session may end with a candidate"
                )
            }
        } else if manifest.phase == .interviewerProcessing {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "interviewer-processing phase requires a pending candidate"
            )
        }

        let commandIDSet = Set(manifest.appliedCommands.lazy.map(\.commandID))
        guard commandIDSet.count == manifest.appliedCommands.count,
              manifest.appliedCommands.allSatisfy({
                  $0.resultingRevision > 0 && $0.resultingRevision <= manifest.revision
              }) else {
            throw InterviewRoomSessionError.invalidManifest(reason: "invalid command receipts")
        }

        let segmentIDs = manifest.segments.map(\.id)
        guard Set(segmentIDs).count == segmentIDs.count,
              manifest.segments.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }),
              manifest.segments.filter(isActiveSegment).count <= 1 else {
            throw InterviewRoomSessionError.invalidManifest(reason: "invalid segment ordering")
        }

        let candidateTurns: [CandidateTurn] = manifest.turns.compactMap {
            guard case .candidate(let candidate) = $0 else { return nil }
            return candidate
        }
        let candidateTurnIDs = candidateTurns.map(\.id)
        guard Set(candidateTurnIDs).count == candidateTurnIDs.count else {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "duplicate Candidate Turn IDs"
            )
        }
        try validateBoardWorkspace(
            manifest.board,
            sessionID: manifest.sessionID,
            appliedCommandIDs: commandIDSet,
            candidateTurns: candidateTurns
        )
        let turnByID = Dictionary(uniqueKeysWithValues: candidateTurns.map { ($0.id, $0) })
        var referencedSegmentIDs = Set<SegmentID>()
        let segmentByID = Dictionary(uniqueKeysWithValues: manifest.segments.map { ($0.id, $0) })
        for turn in candidateTurns {
            guard Set(turn.segmentIDs).count == turn.segmentIDs.count else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "Candidate Turn references a Segment more than once"
                )
            }
            let referenced = try turn.segmentIDs.map { segmentID -> CandidateSegment in
                guard let segment = segmentByID[segmentID] else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "Candidate Turn references a missing Segment"
                    )
                }
                return segment
            }
            guard referenced.map(\.ordinal) == referenced.map(\.ordinal).sorted() else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "Candidate Turn Segment membership is out of order"
                )
            }
            for segment in referenced {
                guard referencedSegmentIDs.insert(segment.id).inserted,
                      segment.committedTurnID == turn.id,
                      segment.lifecycle == .excluded || segment.selectedCandidate != nil else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "Candidate Turn Segment membership is inconsistent"
                    )
                }
            }
        }
        for segment in manifest.segments {
            let attemptIDs = segment.transcriptionAttempts.map(\.id)
            let candidateIDs = segment.transcriptCandidates.map(\.id)
            guard Set(attemptIDs).count == attemptIDs.count,
                  Set(candidateIDs).count == candidateIDs.count,
                  segment.transcriptionAttempts.filter({ $0.state == .authorized }).count <= 1,
                  segment.transcriptCandidates.allSatisfy({ attemptIDs.contains($0.attemptID) }) else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "invalid transcription attempt history"
                )
            }
            if let selected = segment.selectedCandidateID,
               !candidateIDs.contains(selected) {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "selected candidate does not exist"
                )
            }
            if let committedTurnID = segment.committedTurnID {
                guard let turn = turnByID[committedTurnID],
                      turn.segmentIDs.contains(segment.id),
                      referencedSegmentIDs.contains(segment.id) else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "segment commitment does not match Candidate Turn"
                    )
                }
            } else if referencedSegmentIDs.contains(segment.id) {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "uncommitted Segment is referenced by a Candidate Turn"
                )
            }
        }

        let evaluationIDs = manifest.endpointEvaluations.map(\.id)
        let evaluationAuthorizationIDs = manifest.endpointEvaluations.map(
            \.authorizationCommandID
        )
        let evaluationFingerprints = manifest.endpointEvaluations.map(
            \.contextFingerprint
        )
        var candidateOrdinalByID: [TranscriptCandidateID: Int] = [:]
        var hasDuplicateCandidateIdentity = false
        for segment in manifest.segments {
            for candidate in segment.transcriptCandidates {
                if candidateOrdinalByID.updateValue(
                    segment.ordinal,
                    forKey: candidate.id
                ) != nil {
                    hasDuplicateCandidateIdentity = true
                }
            }
        }
        let allCandidateIDs = Set(candidateOrdinalByID.keys)
        let interviewerTurnIDs: Set<TurnID> = Set(manifest.turns.compactMap { turn in
            guard case .interviewer(let interviewer) = turn else { return nil }
            return interviewer.id
        })
        guard Set(evaluationIDs).count == evaluationIDs.count,
              Set(evaluationAuthorizationIDs).count == evaluationAuthorizationIDs.count,
              Set(evaluationFingerprints).count == evaluationFingerprints.count,
              !hasDuplicateCandidateIdentity,
              manifest.endpointEvaluations.filter({ $0.lifecycle == .authorized }).count <= 1
        else {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "invalid endpoint evaluation history"
            )
        }

        for evaluation in manifest.endpointEvaluations {
            do {
                try validateEndpointContextFingerprint(evaluation.contextFingerprint)
            } catch {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "invalid endpoint context fingerprint"
                )
            }
            guard evaluation.id == endpointEvaluationID(
                sessionID: manifest.sessionID,
                commandID: evaluation.authorizationCommandID
            ),
                  commandIDSet.contains(evaluation.authorizationCommandID),
                  !evaluation.selectedCandidateIDs.isEmpty,
                  Set(evaluation.selectedCandidateIDs).count
                    == evaluation.selectedCandidateIDs.count,
                  evaluation.selectedCandidateIDs.allSatisfy(allCandidateIDs.contains),
                  evaluation.questionTurnID.map({
                      interviewerTurnIDs.contains($0)
                  }) ?? true,
                  let triggerSegment = segmentByID[evaluation.triggerSegmentID],
                  triggerSegment.transcriptCandidates.contains(where: {
                      evaluation.selectedCandidateIDs.contains($0.id)
                  }) else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "endpoint evaluation evidence is inconsistent"
                )
            }

            let evidenceOrdinals = try evaluation.selectedCandidateIDs.map {
                candidateID -> Int in
                guard let ordinal = candidateOrdinalByID[candidateID] else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "endpoint evaluation candidate is missing"
                    )
                }
                return ordinal
            }
            guard evidenceOrdinals == evidenceOrdinals.sorted(),
                  Set(evidenceOrdinals).count == evidenceOrdinals.count else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "endpoint evaluation evidence is out of order"
                )
            }

            switch evaluation.lifecycle {
            case .authorized:
                guard evaluation.proposal == nil, evaluation.failure == nil else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "authorized endpoint evaluation has an outcome"
                    )
                }
            case .proposalStored:
                guard let proposal = evaluation.proposal,
                      evaluation.failure == nil else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "stored endpoint proposal is incomplete"
                    )
                }
                do {
                    try validateEndpointEvaluationOutcome(.proposal(proposal))
                } catch {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "stored endpoint proposal is invalid"
                    )
                }
            case .failed:
                guard let failure = evaluation.failure,
                      evaluation.proposal == nil else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "failed endpoint evaluation is incomplete"
                    )
                }
                do {
                    try validateEndpointEvaluationOutcome(.failed(failure))
                } catch {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "stored endpoint failure is invalid"
                    )
                }
            }
        }

        let evaluationByID = Dictionary(
            uniqueKeysWithValues: manifest.endpointEvaluations.map { ($0.id, $0) }
        )
        let graceIDs = manifest.endpointGraces.map(\.id)
        let graceActivationIDs = manifest.endpointGraces.map(\.activationCommandID)
        let graceEvaluationIDs = manifest.endpointGraces.map(\.evaluationID)
        guard Set(graceIDs).count == graceIDs.count,
              Set(graceActivationIDs).count == graceActivationIDs.count,
              Set(graceEvaluationIDs).count == graceEvaluationIDs.count,
              manifest.endpointGraces.filter({ $0.lifecycle == .pending }).count <= 1 else {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "invalid Endpoint Grace history"
            )
        }
        for grace in manifest.endpointGraces {
            guard grace.id == endpointGraceID(
                sessionID: manifest.sessionID,
                commandID: grace.activationCommandID
            ),
            commandIDSet.contains(grace.activationCommandID),
            let evaluation = evaluationByID[grace.evaluationID],
            evaluation.lifecycle == .proposalStored,
            evaluation.proposal?.decision == .likelyEnd,
            evaluation.selectedCandidateIDs == grace.selectedCandidateIDs else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "Endpoint Grace evidence is inconsistent"
                )
            }

            switch grace.lifecycle {
            case .pending:
                guard grace.cancellationReason == nil,
                      grace.completedCandidateTurnID == nil,
                      manifest.phase == .candidateFloor,
                      manifest.turnMode.usesAutomaticEndpointCompletion,
                      manifest.floorHolds.activeHold == nil,
                      isCurrentEndpointEvaluation(
                          evaluation,
                          phase: manifest.phase,
                          mode: manifest.turnMode,
                          turns: manifest.turns,
                          segments: manifest.segments
                      ) else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "pending Endpoint Grace is not current"
                    )
                }
            case .cancelled:
                guard grace.cancellationReason != nil,
                      grace.completedCandidateTurnID == nil else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "cancelled Endpoint Grace is incomplete"
                    )
                }
            case .completed:
                guard grace.cancellationReason == nil,
                      let turnID = grace.completedCandidateTurnID,
                      let candidate = turnByID[turnID] else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "completed Endpoint Grace has no Candidate Turn"
                    )
                }
                let turnCandidateIDs = candidate.segmentIDs.compactMap { segmentID in
                    segmentByID[segmentID]?.selectedCandidateID
                }
                guard turnCandidateIDs == grace.selectedCandidateIDs else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "completed Endpoint Grace Turn evidence is inconsistent"
                    )
                }
            }
        }

        let holdIDs = manifest.floorHolds.map(\.id)
        let holdActivationIDs = manifest.floorHolds.map(\.activationCommandID)
        guard Set(holdIDs).count == holdIDs.count,
              Set(holdActivationIDs).count == holdActivationIDs.count,
              manifest.floorHolds.filter({ $0.lifecycle == .active }).count <= 1 else {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "invalid Floor Hold history"
            )
        }
        for hold in manifest.floorHolds {
            guard hold.id == floorHoldID(
                sessionID: manifest.sessionID,
                commandID: hold.activationCommandID
            ),
            commandIDSet.contains(hold.activationCommandID) else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "Floor Hold identity is inconsistent"
                )
            }
            switch hold.lifecycle {
            case .active:
                guard hold.releaseReason == nil,
                      hold.releaseCommandID == nil,
                      hold.completedCandidateTurnID == nil,
                      manifest.phase == .candidateFloor,
                      manifest.turnMode == .continuousConversation else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "active Floor Hold is not current"
                    )
                }
            case .released:
                guard let reason = hold.releaseReason,
                      let releaseCommandID = hold.releaseCommandID,
                      commandIDSet.contains(releaseCommandID) else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "released Floor Hold is incomplete"
                    )
                }
                if reason == .sendAnswer {
                    guard let turnID = hold.completedCandidateTurnID,
                          turnByID[turnID] != nil else {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "Send answer Floor Hold has no Candidate Turn"
                        )
                    }
                } else {
                    guard hold.completedCandidateTurnID == nil else {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "cancelled Floor Hold should not complete a Turn"
                        )
                    }
                }
            }
        }

        let interviewerTurns: [TurnID: InterviewerTurn] = Dictionary(
            uniqueKeysWithValues: manifest.turns.compactMap { turn in
                guard case .interviewer(let interviewer) = turn else { return nil }
                return (interviewer.id, interviewer)
            }
        )
        var utteranceIDs = Set<InterviewerUtteranceID>()
        var utteranceTurnIDs = Set<TurnID>()
        var synthesisAttemptIDs = Set<SynthesisAttemptID>()
        var activeSynthesisAttemptCount = 0
        for utterance in manifest.interviewerUtterances {
            guard utteranceIDs.insert(utterance.id).inserted,
                  utteranceTurnIDs.insert(utterance.turnID).inserted else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "invalid interviewer speech identity or single-flight state"
                )
            }
            for attempt in utterance.synthesisAttempts {
                guard synthesisAttemptIDs.insert(attempt.id).inserted else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "invalid interviewer speech identity or single-flight state"
                    )
                }
                if isActiveSynthesisAttempt(attempt) {
                    activeSynthesisAttemptCount += 1
                    guard activeSynthesisAttemptCount <= 1 else {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "invalid interviewer speech identity or single-flight state"
                        )
                    }
                }
            }
        }

        for utterance in manifest.interviewerUtterances {
            guard let turn = interviewerTurns[utterance.turnID],
                  utterance.id == interviewerUtteranceID(
                      sessionID: manifest.sessionID,
                      turnID: utterance.turnID
                  ),
                  utterance.spokenTextFingerprint == digest(
                      Data(turn.spokenText.utf8),
                      namespace: "interviewer-spoken-text"
                  ) else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "interviewer utterance does not match its canonical Turn"
                )
            }

            for (attemptIndex, attempt) in utterance.synthesisAttempts.enumerated() {
                do {
                    try validateSpeechProvenance(attempt.provenance)
                    let expectedIdentities = try synthesisAudioIdentities(attemptID: attempt.id)
                    guard attempt.id == synthesisAttemptID(
                        sessionID: manifest.sessionID,
                        utteranceID: utterance.id,
                        commandID: attempt.authorizationCommandID
                    ),
                    attempt.partialAudioIdentity == expectedIdentities.partial,
                    attempt.finalAudioIdentity == expectedIdentities.final,
                    commandIDSet.contains(attempt.authorizationCommandID),
                    (attemptIndex == 0 ? attempt.kind == .initial : attempt.kind == .retry)
                    else {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "Synthesis Attempt provenance is inconsistent"
                        )
                    }
                } catch let error as InterviewRoomSessionError {
                    if case .invalidManifest = error { throw error }
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "Synthesis Attempt provenance is invalid"
                    )
                } catch {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "Synthesis Attempt audio identity is invalid"
                    )
                }

                switch attempt.lifecycle {
                case .authorized, .speaking:
                    guard attempt.audio == nil,
                          attempt.failure == nil,
                          attempt.stopReason == nil else {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "active Synthesis Attempt has an outcome"
                        )
                    }
                case .ready:
                    guard let audio = attempt.audio,
                          attempt.failure == nil,
                          attempt.stopReason == nil else {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "ready Synthesis Attempt has no selected audio"
                        )
                    }
                    do {
                        try validateSynthesisAudio(
                            audio,
                            expectedIdentity: attempt.finalAudioIdentity
                        )
                    } catch {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "ready Synthesis Attempt audio is invalid"
                        )
                    }
                case .stopped:
                    guard attempt.audio == nil,
                          attempt.failure == nil,
                          attempt.stopReason != nil else {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "stopped Synthesis Attempt is incomplete"
                        )
                    }
                case .failed:
                    guard attempt.audio == nil,
                          attempt.failure != nil,
                          attempt.stopReason == nil else {
                        throw InterviewRoomSessionError.invalidManifest(
                            reason: "failed Synthesis Attempt is incomplete"
                        )
                    }
                }
            }

            let selectedAttempt = utterance.selectedAttemptID.flatMap { selectedID in
                utterance.synthesisAttempts.first(where: { $0.id == selectedID })
            }
            let latestReadyAttempt = utterance.synthesisAttempts.last(where: {
                $0.lifecycle == .ready
            })
            if utterance.selectedAttemptID != nil {
                guard selectedAttempt?.lifecycle == .ready,
                      selectedAttempt?.audio != nil,
                      selectedAttempt?.id == latestReadyAttempt?.id else {
                    throw InterviewRoomSessionError.invalidManifest(
                        reason: "selected interviewer audio is not the latest ready Attempt"
                    )
                }
            } else if latestReadyAttempt != nil {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "latest ready interviewer audio is not selected"
                )
            }
            let latest = utterance.synthesisAttempts.last
            let lifecycleIsConsistent: Bool
            switch utterance.lifecycle {
            case .pending:
                lifecycleIsConsistent = utterance.synthesisAttempts.isEmpty
                    && utterance.selectedAttemptID == nil
            case .generating:
                lifecycleIsConsistent = latest?.lifecycle == .authorized
            case .speaking:
                lifecycleIsConsistent = latest?.lifecycle == .speaking
            case .ready:
                lifecycleIsConsistent = selectedAttempt?.lifecycle == .ready
                    && latest.map({ !isActiveSynthesisAttempt($0) }) == true
            case .stopped:
                lifecycleIsConsistent = utterance.selectedAttemptID == nil
                    && latest?.lifecycle == .stopped
            case .failed:
                lifecycleIsConsistent = utterance.selectedAttemptID == nil
                    && latest?.lifecycle == .failed
            }
            guard lifecycleIsConsistent else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "Interviewer Utterance lifecycle is inconsistent"
                )
            }
        }

        if manifest.phase == .ready && !manifest.turns.isEmpty {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "ready session cannot contain turns"
            )
        }
        if manifest.phase == .interviewerTurn && manifest.turns.isEmpty {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "interviewer phase requires a completed turn pair"
            )
        }
    }
}
