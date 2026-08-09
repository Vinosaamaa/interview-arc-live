import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore

typealias VoiceCoreTranscriberFactory = @Sendable (String) -> any SpeechTranscribing
typealias VoiceCoreIntegrityEvaluator = @Sendable (
    URL,
    String,
    TranscriptionResult
) -> TranscriptionIntegrityResult

public actor VoiceCoreSegmentTranscriber: SegmentTranscribing {
    private static let vocabularyPrompt =
        "Preserve punctuation, names, acronyms, and technical terminology."

    private let paths: LiveVoicePaths
    private let fileManager: FileManager
    private let makeTranscriber: VoiceCoreTranscriberFactory
    private let evaluateIntegrity: VoiceCoreIntegrityEvaluator
    private let scratchCleanupPolicy: ProviderScratchCleanupPolicy
    private let now: @Sendable () -> Date
    private var didCompleteInitialScratchCleanup = false

    public init() {
        paths = LiveVoicePaths()
        fileManager = .default
        makeTranscriber = {
            GroqTranscriber(
                apiKey: $0,
                session: URLSession(configuration: .ephemeral)
            )
        }
        evaluateIntegrity = { audioURL, prompt, transcription in
            Self.productionIntegrityEvaluation(
                audioURL: audioURL,
                prompt: prompt,
                transcription: transcription
            )
        }
        scratchCleanupPolicy = .production
        now = Date.init
    }

    init(
        applicationSupportRoot: URL,
        fileManager: FileManager = .default,
        makeTranscriber: @escaping VoiceCoreTranscriberFactory,
        evaluateIntegrity: @escaping VoiceCoreIntegrityEvaluator,
        scratchCleanupPolicy: ProviderScratchCleanupPolicy = .production,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        paths = LiveVoicePaths(applicationSupportRoot: applicationSupportRoot)
        self.fileManager = fileManager
        self.makeTranscriber = makeTranscriber
        self.evaluateIntegrity = evaluateIntegrity
        self.scratchCleanupPolicy = scratchCleanupPolicy
        self.now = now
    }

    public func transcribe(
        _ request: SegmentTranscriptionRequest,
        credential: String
    ) async throws -> SegmentTranscriptionResult {
        cleanupStaleScratchOnFirstUse()

        let normalizedCredential = credential.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedCredential.isEmpty else {
            throw SegmentTranscriptionAdapterFailure(reason: .missingCredential)
        }

        let audioURL = try sourceAudioURL(for: request)
        let scratchURL: URL
        do {
            scratchURL = try paths.transcriptionScratchDirectory(
                sessionID: request.sessionID,
                attemptID: request.attemptID,
                fileManager: fileManager
            )
        } catch {
            throw SegmentTranscriptionAdapterFailure(reason: .invalidAudio)
        }
        defer { try? fileManager.removeItem(at: scratchURL) }

        let transcriber = makeTranscriber(normalizedCredential)
        let transcription: TranscriptionResult
        do {
            switch request.kind {
            case .initial:
                transcription = try await transcriber.transcribe(
                    fileURL: audioURL,
                    prompt: Self.vocabularyPrompt,
                    temporaryDirectory: scratchURL
                )
            case .retry:
                transcription = try await transcriber.transcribeCoverageRecovery(
                    fileURL: audioURL,
                    temporaryDirectory: scratchURL
                )
            }
        } catch {
            throw Self.safeFailure(for: error)
        }

        guard !transcription.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw SegmentTranscriptionAdapterFailure(
                reason: .emptyProviderResult
            )
        }

        let integrity = evaluateIntegrity(
            audioURL,
            request.kind == .initial ? Self.vocabularyPrompt : "",
            transcription
        )
        let quality: TranscriptQuality
        if integrity.reasons.contains(.promptLeakage) {
            quality = .possibleContamination
        } else if integrity.isSuspicious {
            quality = .bestAvailable
        } else {
            quality = .verified
        }

        return SegmentTranscriptionResult(
            body: transcription.text,
            quality: quality,
            integrityReasons: integrity.reasons.map {
                SegmentIntegrityReason($0.rawValue)
            }
        )
    }

    private func cleanupStaleScratchOnFirstUse() {
        guard !didCompleteInitialScratchCleanup else { return }
        do {
            try paths.cleanupStaleTranscriptionScratch(
                now: now(),
                policy: scratchCleanupPolicy,
                fileManager: fileManager
            )
            didCompleteInitialScratchCleanup = true
        } catch {
            // Cleanup must not discard a requested transcription. Leave the
            // flag unset so a later explicit attempt gets another bounded try.
        }
    }

    private func sourceAudioURL(
        for request: SegmentTranscriptionRequest
    ) throws -> URL {
        do {
            let url = try paths.audioURL(
                sessionID: request.sessionID,
                identity: request.audioIdentity,
                createParentDirectory: false,
                fileManager: fileManager
            )
            try paths.validateSourceAudio(at: url, fileManager: fileManager)
            return url
        } catch {
            throw SegmentTranscriptionAdapterFailure(reason: .invalidAudio)
        }
    }

    private static func productionIntegrityEvaluation(
        audioURL: URL,
        prompt: String,
        transcription: TranscriptionResult
    ) -> TranscriptionIntegrityResult {
        let speechEvidence = try? LocalSpeechEvidenceAnalyzer.inspect(audioURL)
        let audioDuration = speechEvidence?.analyzedDurationSeconds
            ?? transcription.durationSeconds
        let trailingSpeech = speechEvidence?.evidence(
            from: transcription.durationSeconds,
            to: audioDuration
        ).hasSustainedSpeech ?? false
        return TranscriptionIntegrityEvaluator.evaluate(
            TranscriptionIntegrityEvidence(
                audioDurationSeconds: audioDuration,
                providerDurationSeconds: transcription.durationSeconds,
                expectedChunkCount: transcription.chunkCount,
                returnedChunkCount: transcription.chunkCount,
                transcript: transcription.text,
                prompt: prompt,
                hasSustainedSpeechAfterProviderCoverage: trailingSpeech
            )
        )
    }

    private static func safeFailure(for error: Error) -> SegmentTranscriptionAdapterFailure {
        if error is CancellationError {
            return SegmentTranscriptionAdapterFailure(reason: .interrupted)
        }
        guard let voiceError = error as? VoiceBridgeError else {
            return SegmentTranscriptionAdapterFailure(
                reason: .providerUnavailable,
                providerCode: .unknown
            )
        }
        switch voiceError {
        case .invalidProviderCredential:
            return SegmentTranscriptionAdapterFailure(
                reason: .credentialRejected,
                providerCode: .unauthorized
            )
        case .providerPermissionDenied:
            return SegmentTranscriptionAdapterFailure(
                reason: .providerUnavailable,
                providerCode: .invalidRequest
            )
        case .providerResponseFailure(let status, _),
             .invalidResponse(let status, _):
            if status == 401 {
                return SegmentTranscriptionAdapterFailure(
                    reason: .credentialRejected,
                    providerCode: .unauthorized
                )
            }
            return SegmentTranscriptionAdapterFailure(
                reason: .providerUnavailable,
                providerCode: providerCode(for: status)
            )
        case .emptyTranscript:
            return SegmentTranscriptionAdapterFailure(
                reason: .emptyProviderResult
            )
        case .microphoneDenied,
             .recordingUnavailable,
             .incompleteRecording:
            return SegmentTranscriptionAdapterFailure(reason: .invalidAudio)
        case .missingCredential:
            return SegmentTranscriptionAdapterFailure(reason: .missingCredential)
        case .suspiciousTranscript:
            return SegmentTranscriptionAdapterFailure(
                reason: .providerUnavailable,
                providerCode: .unknown
            )
        case .noFocusedActivity,
             .noSpecialist,
             .protocolMismatch,
             .codexUnavailable:
            return SegmentTranscriptionAdapterFailure(
                reason: .providerUnavailable,
                providerCode: .unknown
            )
        }
    }

    private static func providerCode(
        for status: Int
    ) -> SegmentTranscriptionProviderCode {
        switch status {
        case 401:
            .unauthorized
        case 429:
            .rateLimited
        case 400..<500:
            .invalidRequest
        case 500..<600:
            .unavailable
        default:
            .unknown
        }
    }
}
