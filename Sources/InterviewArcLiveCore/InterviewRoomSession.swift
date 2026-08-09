import CryptoKit
import Foundation

public enum InterviewRoomCommand: Codable, Sendable, Equatable {
    case giveCandidateFloor(commandID: CommandID)
    case setTurnMode(commandID: CommandID, mode: TurnMode)
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
    case excludeSegment(
        commandID: CommandID,
        segmentID: SegmentID,
        reason: SegmentExclusionReason
    )
    case handOffSegments(commandID: CommandID)
    case handOff(commandID: CommandID, transcript: CandidateTranscript)
    case retryInterviewerResponse(commandID: CommandID)
    case finish(commandID: CommandID)

    var commandID: CommandID {
        switch self {
        case .giveCandidateFloor(let commandID),
             .setTurnMode(let commandID, _),
             .beginSegment(let commandID),
             .finalizeSegment(let commandID, _),
             .recordSegmentCaptureOutcome(let commandID, _, _),
             .authorizeSegmentTranscription(let commandID, _, _, _),
             .recordSegmentTranscriptionOutcome(let commandID, _, _, _),
             .excludeSegment(let commandID, _, _),
             .handOffSegments(let commandID),
             .handOff(let commandID, _),
             .retryInterviewerResponse(let commandID),
             .finish(let commandID):
            commandID
        }
    }
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
    case invalidInterviewerResponse
    case commandIDReused(CommandID)
    case commandInProgress
    case commandEncodingFailed
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
    case noTranscribedSegments
    case unresolvedSegmentsPreventHandOff([SegmentID])
    case uncommittedSegmentsRequireSegmentHandOff
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
        turnMode: TurnMode = .manual,
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

        let snapshot: InterviewRoomSnapshot
        switch command {
        case .handOff(let commandID, let transcript):
            snapshot = try await handOff(
                commandID: commandID,
                transcript: transcript,
                segmentIDs: [],
                fingerprint: fingerprint
            )

        case .handOffSegments(let commandID):
            snapshot = try await handOffSegments(
                commandID: commandID,
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
            mode = selectedMode

        case .beginSegment(let commandID):
            guard phase == .candidateFloor else {
                throw invalidTransition("beginSegment")
            }
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

        case .handOff, .handOffSegments, .retryInterviewerResponse:
            preconditionFailure("Provider commands use their durable two-stage paths")

        case .finish:
            guard phase == .ready || phase == .interviewerTurn else {
                throw invalidTransition("finish")
            }
            phase = .completed
        }

        return appendingReceipt(
            command: command,
            fingerprint: fingerprint,
            phase: phase,
            turnMode: mode,
            turns: manifest.turns,
            segments: segments
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
                  capture.isPlayable,
                  capture.byteCount > 0,
                  capture.startedAtMilliseconds >= 0,
                  capture.endedAtMilliseconds >= capture.startedAtMilliseconds,
                  capture.durationMilliseconds >= 0,
                  capture.decodedDurationMilliseconds > 0 else {
                throw InterviewRoomSessionError.invalidCapturedAudio
            }
            segment.capturedAudio = capture
            segment.captureFailureReason = nil
            segment.lifecycle = .audioReady

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
            fingerprint: fingerprint
        )
    }

    /// Hand off is deliberately two durable transitions. The Candidate Turn
    /// and its Segment associations are saved before provider work starts.
    private func handOff(
        commandID: CommandID,
        transcript: CandidateTranscript,
        segmentIDs: [SegmentID],
        fingerprint: String
    ) async throws -> InterviewRoomSnapshot {
        guard manifest.phase == .candidateFloor else {
            throw invalidTransition(segmentIDs.isEmpty ? "handOff" : "handOffSegments")
        }
        guard !transcript.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterviewRoomSessionError.emptyCandidateTranscript
        }
        if segmentIDs.isEmpty,
           manifest.segments.contains(where: { $0.committedTurnID == nil }) {
            throw InterviewRoomSessionError.uncommittedSegmentsRequireSegmentHandOff
        }

        let candidate = CandidateTurn(
            id: Self.turnID(
                sessionID: manifest.sessionID,
                commandID: commandID,
                role: "candidate"
            ),
            commandID: commandID,
            transcript: transcript,
            segmentIDs: segmentIDs
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
            phase: .interviewerProcessing,
            turnMode: manifest.turnMode,
            turns: manifest.turns + [.candidate(candidate)],
            segments: segments,
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
            phase: .interviewerProcessing,
            turnMode: manifest.turnMode,
            turns: manifest.turns,
            segments: manifest.segments,
            revision: manifest.revision + 1,
            appliedCommands: manifest.appliedCommands + [receipt]
        )
        try await persist(pendingRetry)

        return try await completeInterviewerResponse(for: candidate)
    }

    private func completeInterviewerResponse(
        for candidate: CandidateTurn
    ) async throws -> InterviewRoomSnapshot {
        let request = InterviewerRequest(
            sessionID: manifest.sessionID,
            activityID: manifest.activityID,
            candidateTurn: candidate,
            precedingTurns: Array(manifest.turns.dropLast())
        )
        let response = try await interviewerRuntime.respond(to: request)
        guard !response.displayMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterviewRoomSessionError.invalidInterviewerResponse
        }

        let interviewer = InterviewerTurn(
            id: Self.turnID(
                sessionID: manifest.sessionID,
                commandID: candidate.commandID,
                role: "interviewer"
            ),
            commandID: candidate.commandID,
            replyToTurnID: candidate.id,
            response: response
        )
        let completed = SessionManifest(
            sessionID: manifest.sessionID,
            activityID: manifest.activityID,
            phase: .interviewerTurn,
            turnMode: manifest.turnMode,
            turns: manifest.turns + [.interviewer(interviewer)],
            segments: manifest.segments,
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
        segments: [CandidateSegment]
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
            phase: phase,
            turnMode: turnMode,
            turns: turns,
            segments: segments,
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

    private func invalidTransition(_ command: String) -> InterviewRoomSessionError {
        .invalidTransition(command: command, phase: manifest.phase)
    }

    private static func isActiveSegment(_ segment: CandidateSegment) -> Bool {
        segment.lifecycle == .captureAuthorized
            || segment.lifecycle == .recording
            || segment.lifecycle == .finalizationAuthorized
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
                  interviewer.commandID == candidate.commandID else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "turns must be ordered candidate then matching interviewer"
                )
            }
            index += 2
        }

        if index < manifest.turns.count {
            guard manifest.phase == .interviewerProcessing,
                  index == manifest.turns.count - 1,
                  case .candidate = manifest.turns[index] else {
                throw InterviewRoomSessionError.invalidManifest(
                    reason: "only an interviewer-processing session may end with a candidate"
                )
            }
        } else if manifest.phase == .interviewerProcessing {
            throw InterviewRoomSessionError.invalidManifest(
                reason: "interviewer-processing phase requires a pending candidate"
            )
        }

        let commandIDs = manifest.appliedCommands.map(\.commandID)
        guard Set(commandIDs).count == commandIDs.count,
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
