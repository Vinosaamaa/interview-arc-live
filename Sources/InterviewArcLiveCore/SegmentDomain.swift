import Foundation

public struct SegmentID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct TranscriptionAttemptID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct TranscriptCandidateID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum SegmentAudioIdentityError: Error, Codable, Sendable, Equatable {
    case invalidFileName
}

/// A portable identity for one Live-owned source M4A.
///
/// It is deliberately a filename rather than a path. The recording Adapter
/// resolves it beneath the session-private root; manifests never contain an
/// absolute or caller-constructed path.
public struct SegmentAudioIdentity: Hashable, Sendable, Equatable {
    public let fileName: String

    public init(validating fileName: String) throws {
        guard Self.isValid(fileName) else {
            throw SegmentAudioIdentityError.invalidFileName
        }
        self.fileName = fileName
    }

    private static func isValid(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName.utf8.count <= 200,
              !fileName.hasPrefix("."),
              fileName.lowercased().hasSuffix(".m4a") else {
            return false
        }

        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ."
        )
        return fileName.unicodeScalars.allSatisfy(allowed.contains)
            && !fileName.contains(" ")
            && !fileName.contains("..")
            && !fileName.contains("/")
            && !fileName.contains("\\")
    }
}

extension SegmentAudioIdentity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fileName)
    }
}

public struct SegmentIntegrityReason: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let insufficientSignal = SegmentIntegrityReason("insufficientSignal")
}

public struct SegmentCaptureRequest: Sendable, Equatable {
    public let sessionID: SessionID
    public let segmentID: SegmentID
    public let reservedAudioIdentity: SegmentAudioIdentity

    public init(
        sessionID: SessionID,
        segmentID: SegmentID,
        reservedAudioIdentity: SegmentAudioIdentity
    ) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.reservedAudioIdentity = reservedAudioIdentity
    }
}

/// Live-owned metadata for the source M4A after the recording Adapter has
/// adopted the authoritative recorder URL beneath its private session root.
public struct CapturedAudioSegment: Codable, Sendable, Equatable {
    public let audioIdentity: SegmentAudioIdentity
    public let startedAtMilliseconds: Int64
    public let endedAtMilliseconds: Int64
    public let durationMilliseconds: Int64
    public let decodedDurationMilliseconds: Int64
    public let byteCount: Int64
    public let isPlayable: Bool
    public let isPartial: Bool
    public let integrityReasons: [SegmentIntegrityReason]

    public init(
        audioIdentity: SegmentAudioIdentity,
        startedAtMilliseconds: Int64,
        endedAtMilliseconds: Int64,
        durationMilliseconds: Int64,
        decodedDurationMilliseconds: Int64,
        byteCount: Int64,
        isPlayable: Bool,
        isPartial: Bool,
        integrityReasons: [SegmentIntegrityReason] = []
    ) {
        self.audioIdentity = audioIdentity
        self.startedAtMilliseconds = startedAtMilliseconds
        self.endedAtMilliseconds = endedAtMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.decodedDurationMilliseconds = decodedDurationMilliseconds
        self.byteCount = byteCount
        self.isPlayable = isPlayable
        self.isPartial = isPartial
        self.integrityReasons = integrityReasons
    }
}

public enum SegmentCaptureFailureReason: String, Codable, Sendable, Equatable {
    case microphoneUnavailable = "microphone_unavailable"
    case captureStartFailed = "capture_start_failed"
    case captureFinalizationFailed = "capture_finalization_failed"
    case noPlayableAudio = "no_playable_audio"
    case storageFailed = "storage_failed"
    case interruptedWithoutAudio = "interrupted_without_audio"
}

public enum SegmentCaptureOutcome: Codable, Sendable, Equatable {
    case recordingStarted
    case finalized(CapturedAudioSegment)
    case failed(SegmentCaptureFailureReason)
}

public enum SegmentTranscriptionKind: String, Codable, Sendable, Equatable {
    case initial
    case retry
}

public struct SegmentTranscriptionRequest: Sendable, Equatable {
    public let sessionID: SessionID
    public let segmentID: SegmentID
    public let attemptID: TranscriptionAttemptID
    public let kind: SegmentTranscriptionKind
    public let audioIdentity: SegmentAudioIdentity

    public init(
        sessionID: SessionID,
        segmentID: SegmentID,
        attemptID: TranscriptionAttemptID,
        kind: SegmentTranscriptionKind,
        audioIdentity: SegmentAudioIdentity
    ) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.attemptID = attemptID
        self.kind = kind
        self.audioIdentity = audioIdentity
    }
}

/// One exact provider result. The caller persists it before authorizing any
/// later attempt; the session Module never paraphrases a nonempty body.
public struct SegmentTranscriptionResult: Codable, Sendable, Equatable {
    public let body: String
    public let quality: TranscriptQuality
    public let integrityReasons: [SegmentIntegrityReason]

    public init(
        body: String,
        quality: TranscriptQuality,
        integrityReasons: [SegmentIntegrityReason] = []
    ) {
        self.body = body
        self.quality = quality
        self.integrityReasons = integrityReasons
    }
}

public enum SegmentTranscriptionFailureReason: String, Codable, Sendable, Equatable {
    case missingCredential = "missing_credential"
    case credentialRejected = "credential_rejected"
    case invalidAudio = "invalid_audio"
    case insufficientSignal = "insufficient_signal"
    case emptyProviderResult = "empty_provider_result"
    case providerUnavailable = "provider_unavailable"
    case interrupted = "interrupted"
}

public enum SegmentTranscriptionProviderCode: String, Codable, Sendable, Equatable {
    case unauthorized
    case rateLimited = "rate_limited"
    case invalidRequest = "invalid_request"
    case unavailable
    case unknown
}

/// Privacy-safe provider failure metadata. `credentialFingerprint` is a
/// one-way SHA-256 identity used only to prevent an unchanged rejected key
/// from being retried forever; a credential value is never persisted.
public struct SegmentTranscriptionFailure: Codable, Sendable, Equatable {
    public let reason: SegmentTranscriptionFailureReason
    public let providerCode: SegmentTranscriptionProviderCode?
    public let credentialFingerprint: String?

    public init(
        reason: SegmentTranscriptionFailureReason,
        providerCode: SegmentTranscriptionProviderCode? = nil,
        credentialFingerprint: String? = nil
    ) {
        self.reason = reason
        self.providerCode = providerCode
        self.credentialFingerprint = credentialFingerprint
    }
}

/// A domain-safe failure an Adapter may throw without exposing provider body,
/// prompt, credential, or transcript data to diagnostics.
public struct SegmentTranscriptionAdapterFailure: Error, Sendable, Equatable {
    public let reason: SegmentTranscriptionFailureReason
    public let providerCode: SegmentTranscriptionProviderCode?

    public init(
        reason: SegmentTranscriptionFailureReason,
        providerCode: SegmentTranscriptionProviderCode? = nil
    ) {
        self.reason = reason
        self.providerCode = providerCode
    }
}

public enum SegmentTranscriptionOutcome: Codable, Sendable, Equatable {
    case candidate(SegmentTranscriptionResult)
    case failed(SegmentTranscriptionFailure)
}

public enum CandidateSegmentLifecycle: String, Codable, Sendable, Equatable {
    case captureAuthorized = "capture_authorized"
    case recording
    case finalizationAuthorized = "finalization_authorized"
    case audioReady = "audio_ready"
    case transcribing
    case transcribed
    case failed
    case excluded
}

public enum SegmentExclusionReason: String, Codable, Sendable, Equatable {
    case userSkipped = "user_skipped"
    case noUsableTranscript = "no_usable_transcript"
    case insufficientSignal = "insufficient_signal"
    case captureFailed = "capture_failed"
}

public enum SegmentTranscriptionAttemptState: String, Codable, Sendable, Equatable {
    case authorized
    case candidateStored = "candidate_stored"
    case failed
}

public struct SegmentTranscriptCandidate: Codable, Sendable, Equatable, Identifiable {
    public let id: TranscriptCandidateID
    public let attemptID: TranscriptionAttemptID
    public let body: String
    public let quality: TranscriptQuality
    public let integrityReasons: [SegmentIntegrityReason]

    public init(
        id: TranscriptCandidateID,
        attemptID: TranscriptionAttemptID,
        body: String,
        quality: TranscriptQuality,
        integrityReasons: [SegmentIntegrityReason]
    ) {
        self.id = id
        self.attemptID = attemptID
        self.body = body
        self.quality = quality
        self.integrityReasons = integrityReasons
    }
}

public struct SegmentTranscriptionAttempt: Codable, Sendable, Equatable, Identifiable {
    public let id: TranscriptionAttemptID
    public let authorizationCommandID: CommandID
    public let kind: SegmentTranscriptionKind
    public internal(set) var state: SegmentTranscriptionAttemptState
    public internal(set) var candidateID: TranscriptCandidateID?
    public internal(set) var credentialFingerprint: String
    public internal(set) var failure: SegmentTranscriptionFailure?

    init(
        id: TranscriptionAttemptID,
        authorizationCommandID: CommandID,
        kind: SegmentTranscriptionKind,
        state: SegmentTranscriptionAttemptState = .authorized,
        candidateID: TranscriptCandidateID? = nil,
        credentialFingerprint: String,
        failure: SegmentTranscriptionFailure? = nil
    ) {
        self.id = id
        self.authorizationCommandID = authorizationCommandID
        self.kind = kind
        self.state = state
        self.candidateID = candidateID
        self.credentialFingerprint = credentialFingerprint
        self.failure = failure
    }
}

public struct CandidateSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: SegmentID
    public let ordinal: Int
    public let reservationCommandID: CommandID
    public let reservedAudioIdentity: SegmentAudioIdentity
    public internal(set) var lifecycle: CandidateSegmentLifecycle
    public internal(set) var capturedAudio: CapturedAudioSegment?
    public internal(set) var captureFailureReason: SegmentCaptureFailureReason?
    public internal(set) var transcriptionAttempts: [SegmentTranscriptionAttempt]
    public internal(set) var transcriptCandidates: [SegmentTranscriptCandidate]
    public internal(set) var selectedCandidateID: TranscriptCandidateID?
    public internal(set) var committedTurnID: TurnID?
    public internal(set) var exclusionReason: SegmentExclusionReason?

    init(
        id: SegmentID,
        ordinal: Int,
        reservationCommandID: CommandID,
        reservedAudioIdentity: SegmentAudioIdentity,
        lifecycle: CandidateSegmentLifecycle,
        capturedAudio: CapturedAudioSegment? = nil,
        captureFailureReason: SegmentCaptureFailureReason? = nil,
        transcriptionAttempts: [SegmentTranscriptionAttempt] = [],
        transcriptCandidates: [SegmentTranscriptCandidate] = [],
        selectedCandidateID: TranscriptCandidateID? = nil,
        committedTurnID: TurnID? = nil,
        exclusionReason: SegmentExclusionReason? = nil
    ) {
        self.id = id
        self.ordinal = ordinal
        self.reservationCommandID = reservationCommandID
        self.reservedAudioIdentity = reservedAudioIdentity
        self.lifecycle = lifecycle
        self.capturedAudio = capturedAudio
        self.captureFailureReason = captureFailureReason
        self.transcriptionAttempts = transcriptionAttempts
        self.transcriptCandidates = transcriptCandidates
        self.selectedCandidateID = selectedCandidateID
        self.committedTurnID = committedTurnID
        self.exclusionReason = exclusionReason
    }

    public var selectedCandidate: SegmentTranscriptCandidate? {
        guard let selectedCandidateID else { return nil }
        return transcriptCandidates.first { $0.id == selectedCandidateID }
    }

    public var selectedTranscript: CandidateTranscript? {
        selectedCandidate.map {
            CandidateTranscript(body: $0.body, quality: $0.quality)
        }
    }

    public var canRetryTranscription: Bool {
        capturedAudio?.isPlayable == true
            && capturedAudio?.integrityReasons.contains(.insufficientSignal) == false
            && !transcriptionAttempts.contains(where: { $0.state == .authorized })
            && lifecycle != .failed
            && lifecycle != .excluded
    }

    public var canExcludeFromAnswer: Bool {
        committedTurnID == nil
            && lifecycle != .captureAuthorized
            && lifecycle != .recording
            && lifecycle != .finalizationAuthorized
            && lifecycle != .transcribing
            && lifecycle != .excluded
    }
}

/// Deep capture Adapter: it owns private-root path resolution and adopts the
/// recorder's authoritative returned URL before exposing only a validated
/// identity to Core. SwiftUI never constructs or persists file paths.
@MainActor
public protocol SegmentRecording: AnyObject {
    func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    )

    func beginCapture(_ request: SegmentCaptureRequest) async throws

    func finishCapture() async throws -> CapturedAudioSegment

    /// Inspects/adopts an interrupted source without replaying capture or a
    /// provider request. Nil means no playable partial exists.
    func recoverCapture(_ request: SegmentCaptureRequest) async throws -> CapturedAudioSegment?

    func playbackURL(
        sessionID: SessionID,
        audioIdentity: SegmentAudioIdentity
    ) async throws -> URL
}

/// One invocation means one provider request. An Adapter must not hide a
/// retry inside this call; retry authorization belongs to the session Module.
public protocol SegmentTranscribing: Sendable {
    func transcribe(
        _ request: SegmentTranscriptionRequest,
        credential: String
    ) async throws -> SegmentTranscriptionResult
}

public protocol GroqCredentialReading: Sendable {
    func readGroqCredential() async throws -> String
}
