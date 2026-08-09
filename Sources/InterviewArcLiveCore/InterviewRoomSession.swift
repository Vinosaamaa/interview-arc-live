import Foundation
import CryptoKit

public enum InterviewRoomCommand: Codable, Sendable, Equatable {
    case giveCandidateFloor(commandID: CommandID)
    case setTurnMode(commandID: CommandID, mode: TurnMode)
    case handOff(commandID: CommandID, transcript: CandidateTranscript)
    case retryInterviewerResponse(commandID: CommandID)
    case finish(commandID: CommandID)

    var commandID: CommandID {
        switch self {
        case .giveCandidateFloor(let commandID),
             .setTurnMode(let commandID, _),
             .handOff(let commandID, _),
             .retryInterviewerResponse(let commandID),
             .finish(let commandID):
            commandID
        }
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
}

/// Deep Module owning Interview Room ordering, transitions, idempotency, and
/// persist-before-publish behavior. Callers submit commands and receive only
/// immutable snapshots; they cannot mutate the Session Manifest directly.
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

    /// Applies one command serially. An accepted transition is persisted before
    /// it becomes observable through `snapshot()` or this return value.
    public func execute(_ command: InterviewRoomCommand) async throws -> InterviewRoomSnapshot {
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
            return InterviewRoomSnapshot(manifest: manifest)
        }

        switch command {
        case .handOff(let commandID, let transcript):
            return try await handOff(
                commandID: commandID,
                transcript: transcript,
                fingerprint: fingerprint
            )
        case .retryInterviewerResponse(let commandID):
            return try await retryInterviewerResponse(
                commandID: commandID,
                fingerprint: fingerprint
            )
        default:
            let next = try applyingImmediate(command, fingerprint: fingerprint)
            try await persist(next)
            return InterviewRoomSnapshot(manifest: next)
        }
    }

    private func applyingImmediate(
        _ command: InterviewRoomCommand,
        fingerprint: String
    ) throws -> SessionManifest {
        var phase = manifest.phase
        var mode = manifest.turnMode
        let turns = manifest.turns

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

        case .handOff, .retryInterviewerResponse:
            preconditionFailure("Provider commands use their durable two-stage paths")

        case .finish:
            guard phase == .ready || phase == .interviewerTurn else {
                throw invalidTransition("finish")
            }
            phase = .completed
        }

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
            turnMode: mode,
            turns: turns,
            revision: nextRevision,
            appliedCommands: manifest.appliedCommands + [applied]
        )
    }

    /// Hand off is deliberately two durable transitions. The Candidate Turn is
    /// saved before provider work starts, so a provider failure cannot erase an
    /// accepted answer. Retrying the same Hand off only returns that pending
    /// state; response recovery is an explicit command.
    private func handOff(
        commandID: CommandID,
        transcript: CandidateTranscript,
        fingerprint: String
    ) async throws -> InterviewRoomSnapshot {
        guard manifest.phase == .candidateFloor else {
            throw invalidTransition("handOff")
        }
        guard !transcript.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InterviewRoomSessionError.emptyCandidateTranscript
        }

        let candidate = CandidateTurn(
            id: Self.turnID(
                sessionID: manifest.sessionID,
                commandID: commandID,
                role: "candidate"
            ),
            commandID: commandID,
            transcript: transcript
        )
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
            revision: candidateRevision,
            appliedCommands: manifest.appliedCommands + [receipt]
        )
        try await persist(awaitingResponse)

        return try await completeInterviewerResponse(
            for: candidate
        )
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
            revision: manifest.revision + 1,
            appliedCommands: manifest.appliedCommands + [receipt]
        )
        try await persist(pendingRetry)

        return try await completeInterviewerResponse(
            for: candidate
        )
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
            revision: manifest.revision + 1,
            appliedCommands: manifest.appliedCommands
        )
        try await persist(completed)
        return InterviewRoomSnapshot(manifest: completed)
    }

    private func persist(_ next: SessionManifest) async throws {
        try await manifestStore.save(next, expectedRevision: manifest.revision)
        manifest = next
    }

    private func invalidTransition(_ command: String) -> InterviewRoomSessionError {
        .invalidTransition(command: command, phase: manifest.phase)
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
        let digest = SHA256.hash(data: versionedPayload)
        return "sha256:v1:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func turnID(
        sessionID: SessionID,
        commandID: CommandID,
        role: String
    ) -> TurnID {
        var tuple = Data()
        for field in [
            "interview-room-turn-id",
            "v1",
            sessionID.rawValue,
            commandID.rawValue,
            role,
        ] {
            appendLengthPrefixed(field, to: &tuple)
        }
        let digest = SHA256.hash(data: tuple)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return TurnID("turn:sha256:v1:\(hex)")
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
