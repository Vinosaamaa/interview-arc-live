import CryptoKit
import Foundation

public struct InterviewerUtteranceID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct SynthesisAttemptID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum InterviewerAudioIdentityError: Error, Codable, Sendable, Equatable {
    case invalidFileName
}

/// Portable identity for one private, Live-owned interviewer WAV. A Manifest
/// never retains a path; storage and playback Adapters resolve this basename
/// beneath the session-private utterance root.
public struct InterviewerAudioIdentity: Codable, Hashable, Sendable, Equatable {
    public let fileName: String

    public init(validating fileName: String) throws {
        guard Self.isValid(fileName) else {
            throw InterviewerAudioIdentityError.invalidFileName
        }
        self.fileName = fileName
    }

    private static func isValid(_ fileName: String) -> Bool {
        let prefix = "speech-"
        let suffix: String
        if fileName.hasSuffix(".partial.wav") {
            suffix = ".partial.wav"
        } else if fileName.hasSuffix(".wav") {
            suffix = ".wav"
        } else {
            return false
        }
        guard fileName.hasPrefix(prefix) else { return false }
        let hashStart = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let hashEnd = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        let hash = fileName[hashStart..<hashEnd]
        return hash.count == 64
            && hash.allSatisfy {
                ("0"..."9").contains(String($0))
                    || ("a"..."f").contains(String($0))
            }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fileName)
    }
}

public enum InterviewerSpeechProfileValidationError: Error, Sendable, Equatable {
    case invalidString(name: String, maximumUTF8Bytes: Int)
    case invalidInteger(name: String)
    case invalidNumber(name: String)
}

/// Complete portable generation settings for a named interviewer voice.
/// Every resolved option participates in `fingerprint`, so tuning creates a
/// new profile identity instead of silently changing Attempt provenance.
public struct InterviewerSpeechProfile: Codable, Hashable, Sendable, Equatable {
    public let profileID: String
    public let language: String
    public let conditioning: String
    public let maxTokens: Int
    public let temperature: Double
    public let topP: Double
    public let topK: Int
    public let minP: Double
    public let repetitionPenalty: Double
    public let repetitionContextSize: Int
    public let streamingInterval: Double
    public let fingerprint: String

    public init(
        profileID: String,
        language: String,
        conditioning: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        topK: Int,
        minP: Double,
        repetitionPenalty: Double,
        repetitionContextSize: Int,
        streamingInterval: Double
    ) throws {
        try Self.validateString(profileID, name: "profileID", maximumUTF8Bytes: 128)
        try Self.validateString(language, name: "language", maximumUTF8Bytes: 128)
        try Self.validateString(conditioning, name: "conditioning", maximumUTF8Bytes: 2_048)
        guard (1...10_000).contains(maxTokens) else {
            throw InterviewerSpeechProfileValidationError.invalidInteger(name: "maxTokens")
        }
        guard (0...10_000).contains(topK) else {
            throw InterviewerSpeechProfileValidationError.invalidInteger(name: "topK")
        }
        guard (1...1_000_000).contains(repetitionContextSize) else {
            throw InterviewerSpeechProfileValidationError.invalidInteger(
                name: "repetitionContextSize"
            )
        }
        try Self.validateNumber(temperature, name: "temperature", range: 0...2)
        try Self.validateNumber(topP, name: "topP", range: 0...1)
        try Self.validateNumber(minP, name: "minP", range: 0...1)
        try Self.validateNumber(
            repetitionPenalty,
            name: "repetitionPenalty",
            range: 0.1...10
        )
        try Self.validateNumber(
            streamingInterval,
            name: "streamingInterval",
            range: 0.01...60
        )
        self.profileID = profileID
        self.language = language
        self.conditioning = conditioning
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.streamingInterval = streamingInterval
        fingerprint = Self.makeFingerprint(
            profileID: profileID,
            language: language,
            conditioning: conditioning,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            streamingInterval: streamingInterval
        )
    }

    public static let maraV1: InterviewerSpeechProfile = {
        do {
            return try InterviewerSpeechProfile(
                profileID: "mara-v1",
                language: "English",
                conditioning: "Aiden, calm, precise, warm technical interviewer with natural measured delivery.",
                maxTokens: 1_200,
                temperature: 0.9,
                topP: 1.0,
                topK: 0,
                minP: 0,
                repetitionPenalty: 1.05,
                repetitionContextSize: 20,
                streamingInterval: 0.32
            )
        } catch {
            preconditionFailure("mara-v1 must remain a valid speech profile")
        }
    }()

    private enum CodingKeys: String, CodingKey {
        case profileID
        case language
        case conditioning
        case maxTokens
        case temperature
        case topP
        case topK
        case minP
        case repetitionPenalty
        case repetitionContextSize
        case streamingInterval
        case fingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profileID: try container.decode(String.self, forKey: .profileID),
            language: try container.decode(String.self, forKey: .language),
            conditioning: try container.decode(String.self, forKey: .conditioning),
            maxTokens: try container.decode(Int.self, forKey: .maxTokens),
            temperature: try container.decode(Double.self, forKey: .temperature),
            topP: try container.decode(Double.self, forKey: .topP),
            topK: try container.decodeIfPresent(Int.self, forKey: .topK) ?? 0,
            minP: try container.decodeIfPresent(Double.self, forKey: .minP) ?? 0,
            repetitionPenalty: try container.decode(Double.self, forKey: .repetitionPenalty),
            repetitionContextSize: try container.decodeIfPresent(
                Int.self,
                forKey: .repetitionContextSize
            ) ?? 20,
            streamingInterval: try container.decode(Double.self, forKey: .streamingInterval)
        )
        let stored = try container.decode(String.self, forKey: .fingerprint)
        guard stored == fingerprint else {
            throw DecodingError.dataCorruptedError(
                forKey: .fingerprint,
                in: container,
                debugDescription: "Interviewer speech profile fingerprint does not match settings"
            )
        }
    }

    private static func makeFingerprint(
        profileID: String,
        language: String,
        conditioning: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        topK: Int,
        minP: Double,
        repetitionPenalty: Double,
        repetitionContextSize: Int,
        streamingInterval: Double
    ) -> String {
        let fields = [
            profileID,
            language,
            conditioning,
            String(maxTokens),
            String(temperature.bitPattern),
            String(topP.bitPattern),
            String(topK),
            String(minP.bitPattern),
            String(repetitionPenalty.bitPattern),
            String(repetitionContextSize),
            String(streamingInterval.bitPattern),
        ]
        var payload = Data()
        for field in ["interview-arc-live", "interviewer-speech-profile", "v1"] + fields {
            let bytes = Data(field.utf8)
            let count = UInt64(bytes.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                payload.append(UInt8((count >> UInt64(shift)) & 0xff))
            }
            payload.append(bytes)
        }
        let hex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return "sha256:v1:\(hex)"
    }

    func hasValidFingerprint() -> Bool {
        fingerprint == Self.makeFingerprint(
            profileID: profileID,
            language: language,
            conditioning: conditioning,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize,
            streamingInterval: streamingInterval
        )
    }

    private static func validateString(
        _ value: String,
        name: String,
        maximumUTF8Bytes: Int
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= maximumUTF8Bytes,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw InterviewerSpeechProfileValidationError.invalidString(
                name: name,
                maximumUTF8Bytes: maximumUTF8Bytes
            )
        }
    }

    private static func validateNumber(
        _ value: Double,
        name: String,
        range: ClosedRange<Double>
    ) throws {
        guard value.isFinite, range.contains(value) else {
            throw InterviewerSpeechProfileValidationError.invalidNumber(name: name)
        }
    }
}

public struct InterviewerSpeechProvenance: Codable, Hashable, Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let modelRevision: String
    public let profile: InterviewerSpeechProfile

    public init(
        providerID: String,
        modelID: String,
        modelRevision: String,
        profile: InterviewerSpeechProfile
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.profile = profile
    }
}

public enum InterviewerSpeechPreparationPolicy: String, Sendable, Equatable {
    case neverDownload = "never_download"
    case userAuthorizedDownload = "user_authorized_download"
}

public enum InterviewerSpeechPreparationStage: String, Sendable, Equatable {
    case checkingStorage = "checking_storage"
    case downloading
    case verifying
    case promoting
}

public struct InterviewerSpeechPreparationProgress: Sendable, Equatable {
    public let stage: InterviewerSpeechPreparationStage
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(
        stage: InterviewerSpeechPreparationStage,
        completedBytes: Int64,
        totalBytes: Int64
    ) {
        self.stage = stage
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public enum InterviewerSpeechReadinessFailure: String, Error, Sendable, Equatable {
    case insufficientStorage = "insufficient_storage"
    case networkUnavailable = "network_unavailable"
    case verificationFailed = "verification_failed"
    case incompatibleRuntime = "incompatible_runtime"
    case storageFailure = "storage_failure"
    case cancelled
}

public enum InterviewerSpeechReadiness: Sendable, Equatable {
    case notInstalled
    case preparing(InterviewerSpeechPreparationProgress)
    case ready
    case unavailable(InterviewerSpeechReadinessFailure)
}

public struct InterviewerSpeechSynthesisRequest: Sendable, Equatable {
    public let sessionID: SessionID
    public let turnID: TurnID
    public let utteranceID: InterviewerUtteranceID
    public let attemptID: SynthesisAttemptID
    public let spokenText: String
    public let profile: InterviewerSpeechProfile

    public init(
        sessionID: SessionID,
        turnID: TurnID,
        utteranceID: InterviewerUtteranceID,
        attemptID: SynthesisAttemptID,
        spokenText: String,
        profile: InterviewerSpeechProfile
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.utteranceID = utteranceID
        self.attemptID = attemptID
        self.spokenText = spokenText
        self.profile = profile
    }
}

public struct InterviewerSpeechPCMChunk: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int
    public let channelCount: Int

    public init(samples: [Float], sampleRate: Int, channelCount: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct InterviewerSpeechGenerationMetrics: Sendable, Equatable {
    public let chunkCount: Int
    public let generatedSampleCount: Int
    public let timeToFirstAudioMilliseconds: Int64?
    public let totalGenerationMilliseconds: Int64?

    public init(
        chunkCount: Int,
        generatedSampleCount: Int,
        timeToFirstAudioMilliseconds: Int64?,
        totalGenerationMilliseconds: Int64?
    ) {
        self.chunkCount = chunkCount
        self.generatedSampleCount = generatedSampleCount
        self.timeToFirstAudioMilliseconds = timeToFirstAudioMilliseconds
        self.totalGenerationMilliseconds = totalGenerationMilliseconds
    }
}

public enum InterviewerSpeechEvent: Sendable, Equatable {
    case pcm(InterviewerSpeechPCMChunk)
    case completed(InterviewerSpeechGenerationMetrics)
}

/// One invocation is one local generation attempt. The Adapter must not hide
/// download, retry, fallback, or provider text rewriting inside synthesis.
public protocol InterviewerSpeechProvider: Sendable {
    var provenance: InterviewerSpeechProvenance { get }

    /// Inspection only: no model download, cache repair, or filesystem write.
    func readiness() async -> InterviewerSpeechReadiness

    func prepare(
        _ policy: InterviewerSpeechPreparationPolicy,
        progress: @escaping @Sendable (InterviewerSpeechPreparationProgress) -> Void
    ) async throws -> InterviewerSpeechReadiness

    func synthesize(
        _ request: InterviewerSpeechSynthesisRequest
    ) async throws -> AsyncThrowingStream<InterviewerSpeechEvent, Error>

    /// Cancels and joins only the active synthesis producer. A prepared model
    /// remains loaded so an explicit Retry does not race stale provider work or
    /// pay another model-load cost.
    func cancelSynthesis() async
    func unload() async
    func removePreparedModel() async throws -> InterviewerSpeechReadiness
}

public struct InterviewerSpeechAudioWriteRequest: Sendable, Equatable {
    public let sessionID: SessionID
    public let utteranceID: InterviewerUtteranceID
    public let attemptID: SynthesisAttemptID
    public let partialAudioIdentity: InterviewerAudioIdentity
    public let finalAudioIdentity: InterviewerAudioIdentity

    public init(
        sessionID: SessionID,
        utteranceID: InterviewerUtteranceID,
        attemptID: SynthesisAttemptID,
        partialAudioIdentity: InterviewerAudioIdentity,
        finalAudioIdentity: InterviewerAudioIdentity
    ) {
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.attemptID = attemptID
        self.partialAudioIdentity = partialAudioIdentity
        self.finalAudioIdentity = finalAudioIdentity
    }
}

public typealias InterviewerSpeechAudioRecoveryRequest = InterviewerSpeechAudioWriteRequest

public struct InterviewerSpeechAudioArtifact: Codable, Sendable, Equatable {
    public let audioIdentity: InterviewerAudioIdentity
    public let sampleRate: Int
    public let channelCount: Int
    public let durationMilliseconds: Int64
    public let byteCount: Int64
    public let sha256: String

    public init(
        audioIdentity: InterviewerAudioIdentity,
        sampleRate: Int,
        channelCount: Int,
        durationMilliseconds: Int64,
        byteCount: Int64,
        sha256: String
    ) {
        self.audioIdentity = audioIdentity
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.durationMilliseconds = durationMilliseconds
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    func isValidFinalAudio(expectedIdentity: InterviewerAudioIdentity) -> Bool {
        guard audioIdentity == expectedIdentity,
              sampleRate == 24_000,
              channelCount == 1,
              (0...100_000).contains(durationMilliseconds),
              (48...9_600_044).contains(byteCount) else {
            return false
        }
        let payloadByteCount = byteCount - 44
        let sampleCount = payloadByteCount / 4
        let expectedDurationMilliseconds = (sampleCount * 1_000 + 12_000) / 24_000
        return payloadByteCount.isMultiple(of: 4)
            && sampleCount <= 2_400_000
            && durationMilliseconds == expectedDurationMilliseconds
            && sha256.count == 64
            && sha256.allSatisfy {
                ("0"..."9").contains(String($0))
                    || ("a"..."f").contains(String($0))
            }
    }
}

/// The WAV storage Seam owns private paths, deterministic headers, partial
/// cleanup, validation, and atomic rename. Core supplies only stable identities.
public protocol InterviewerSpeechAudioStoring: Sendable {
    func beginWrite(_ request: InterviewerSpeechAudioWriteRequest) async throws
    func append(_ chunk: InterviewerSpeechPCMChunk, attemptID: SynthesisAttemptID) async throws
    func finalizeWrite(attemptID: SynthesisAttemptID) async throws
        -> InterviewerSpeechAudioArtifact
    func discardPartial(attemptID: SynthesisAttemptID) async
    func recoverFinalizedAudio(
        _ request: InterviewerSpeechAudioRecoveryRequest
    ) async throws -> InterviewerSpeechAudioArtifact?
    func validateAudio(
        sessionID: SessionID,
        artifact: InterviewerSpeechAudioArtifact
    ) async -> Bool
}

public struct InterviewerSpeechPlaybackRequest: Sendable, Equatable {
    public let sessionID: SessionID
    public let artifact: InterviewerSpeechAudioArtifact

    public init(sessionID: SessionID, artifact: InterviewerSpeechAudioArtifact) {
        self.sessionID = sessionID
        self.artifact = artifact
    }

    public var audioIdentity: InterviewerAudioIdentity { artifact.audioIdentity }
}

/// Playback remains a separate Seam because streaming and saved-WAV Adapters
/// have independent failure and cancellation behavior from synthesis/storage.
@MainActor
public protocol InterviewerSpeechPlaying: AnyObject {
    func beginStreaming(sampleRate: Int, channelCount: Int) async throws
    func enqueue(_ chunk: InterviewerSpeechPCMChunk) async throws
    func finishStreaming() async throws
    func stop() async
    func play(_ request: InterviewerSpeechPlaybackRequest) async throws
}

public enum InterviewerUtteranceLifecycle: String, Codable, Sendable, Equatable {
    case pending
    case generating
    case speaking
    case ready
    case stopped
    case failed
}

public enum SynthesisAttemptKind: String, Codable, Sendable, Equatable {
    case initial
    case retry
}

public enum SynthesisAttemptLifecycle: String, Codable, Sendable, Equatable {
    case authorized
    case speaking
    case ready
    case stopped
    case failed
}

public enum InterviewerSynthesisStopReason: String, Codable, Sendable, Equatable {
    case userStopped = "user_stopped"
    case muted
}

public enum InterviewerSynthesisFailureReason: String, Codable, Sendable, Equatable {
    case modelUnavailable = "model_unavailable"
    case providerFailed = "provider_failed"
    case invalidAudio = "invalid_audio"
    case storageFailed = "storage_failed"
    case playbackFailed = "playback_failed"
    case interrupted
}

public struct InterviewerSynthesisFailure: Codable, Error, Sendable, Equatable {
    public let reason: InterviewerSynthesisFailureReason

    public init(reason: InterviewerSynthesisFailureReason) {
        self.reason = reason
    }
}

public struct SynthesisAttempt: Codable, Sendable, Equatable, Identifiable {
    public let id: SynthesisAttemptID
    public let authorizationCommandID: CommandID
    public let kind: SynthesisAttemptKind
    public let provenance: InterviewerSpeechProvenance
    public let partialAudioIdentity: InterviewerAudioIdentity
    public let finalAudioIdentity: InterviewerAudioIdentity
    public internal(set) var lifecycle: SynthesisAttemptLifecycle
    public internal(set) var audio: InterviewerSpeechAudioArtifact?
    public internal(set) var failure: InterviewerSynthesisFailure?
    public internal(set) var stopReason: InterviewerSynthesisStopReason?

    init(
        id: SynthesisAttemptID,
        authorizationCommandID: CommandID,
        kind: SynthesisAttemptKind,
        provenance: InterviewerSpeechProvenance,
        partialAudioIdentity: InterviewerAudioIdentity,
        finalAudioIdentity: InterviewerAudioIdentity,
        lifecycle: SynthesisAttemptLifecycle = .authorized,
        audio: InterviewerSpeechAudioArtifact? = nil,
        failure: InterviewerSynthesisFailure? = nil,
        stopReason: InterviewerSynthesisStopReason? = nil
    ) {
        self.id = id
        self.authorizationCommandID = authorizationCommandID
        self.kind = kind
        self.provenance = provenance
        self.partialAudioIdentity = partialAudioIdentity
        self.finalAudioIdentity = finalAudioIdentity
        self.lifecycle = lifecycle
        self.audio = audio
        self.failure = failure
        self.stopReason = stopReason
    }
}

public struct InterviewerUtterance: Codable, Sendable, Equatable, Identifiable {
    public let id: InterviewerUtteranceID
    public let turnID: TurnID
    public let spokenTextFingerprint: String
    public internal(set) var lifecycle: InterviewerUtteranceLifecycle
    public internal(set) var synthesisAttempts: [SynthesisAttempt]
    public internal(set) var selectedAttemptID: SynthesisAttemptID?

    init(
        id: InterviewerUtteranceID,
        turnID: TurnID,
        spokenTextFingerprint: String,
        lifecycle: InterviewerUtteranceLifecycle = .pending,
        synthesisAttempts: [SynthesisAttempt] = [],
        selectedAttemptID: SynthesisAttemptID? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.spokenTextFingerprint = spokenTextFingerprint
        self.lifecycle = lifecycle
        self.synthesisAttempts = synthesisAttempts
        self.selectedAttemptID = selectedAttemptID
    }

    public var selectedAudio: InterviewerSpeechAudioArtifact? {
        guard let selectedAttemptID else { return nil }
        return synthesisAttempts.first(where: { $0.id == selectedAttemptID })?.audio
    }

    public var latestAttempt: SynthesisAttempt? { synthesisAttempts.last }
}

public enum InterviewerSynthesisOutcome: Codable, Sendable, Equatable {
    case ready(InterviewerSpeechAudioArtifact)
    case stopped(InterviewerSynthesisStopReason)
    case failed(InterviewerSynthesisFailure)
}
