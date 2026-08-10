import Foundation
import InterviewArcLiveCore

public enum LiveInterviewerSpeechAudioStoreConfigurationError: Error, Sendable {
    case invalidTemporarySmokeRoot
}

/// Production private-WAV Adapter. Core supplies stable identities and owns
/// authorization/recovery ordering; this actor owns only confined filesystem
/// effects and never exposes a URL through the Core Interface.
public actor LiveInterviewerSpeechAudioStore: InterviewerSpeechAudioStoring {
    private struct ActiveWrite {
        let token: PrivateInterviewerWaveWriteToken
        let request: InterviewerSpeechAudioWriteRequest
    }

    private let store: PrivateInterviewerWaveStore
    private var activeWrites: [String: ActiveWrite] = [:]

    public init() {
        store = PrivateInterviewerWaveStore()
    }

    /// Narrow installed-smoke boundary. The caller owns one fresh, direct
    /// child of the process temporary directory; production session audio can
    /// never be selected through this initializer.
    public init(validatingTemporarySmokeRoot root: URL) throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
        let candidate = root.standardizedFileURL
        let allowedPrefixes = [
            "interview-arc-live-speech-smoke-",
            "interview-arc-live-speech-smoke.",
        ]
        let hasDedicatedName = allowedPrefixes.contains { prefix in
            candidate.lastPathComponent.hasPrefix(prefix)
                && candidate.lastPathComponent.count > prefix.count
        }
        guard candidate.deletingLastPathComponent() == temporaryRoot,
              hasDedicatedName else {
            throw LiveInterviewerSpeechAudioStoreConfigurationError
                .invalidTemporarySmokeRoot
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw LiveInterviewerSpeechAudioStoreConfigurationError
                    .invalidTemporarySmokeRoot
            }
        }
        store = PrivateInterviewerWaveStore(
            applicationSupportRoot: candidate
        )
    }

    init(applicationSupportRoot: URL) {
        store = PrivateInterviewerWaveStore(
            applicationSupportRoot: applicationSupportRoot
        )
    }

    public func beginWrite(
        _ request: InterviewerSpeechAudioWriteRequest
    ) async throws {
        let key = request.attemptID.rawValue
        guard activeWrites[key] == nil else {
            throw PrivateInterviewerWaveStoreError.writeAlreadyActive
        }
        let token = try await store.begin(
            sessionIdentity: request.sessionID.rawValue,
            attemptIdentity: request.attemptID.rawValue,
            partialFileName: request.partialAudioIdentity.fileName,
            finalFileName: request.finalAudioIdentity.fileName
        )
        activeWrites[key] = ActiveWrite(token: token, request: request)
    }

    public func append(
        _ chunk: InterviewerSpeechPCMChunk,
        attemptID: SynthesisAttemptID
    ) async throws {
        guard let active = activeWrites[attemptID.rawValue] else {
            throw PrivateInterviewerWaveStoreError.writeNotActive
        }
        try await store.append(
            chunk.samples,
            sampleRate: chunk.sampleRate,
            channelCount: chunk.channelCount,
            to: active.token
        )
    }

    public func finalizeWrite(
        attemptID: SynthesisAttemptID
    ) async throws -> InterviewerSpeechAudioArtifact {
        let key = attemptID.rawValue
        guard let active = activeWrites[key] else {
            throw PrivateInterviewerWaveStoreError.writeNotActive
        }
        let descriptor = try await store.finalize(active.token)
        activeWrites.removeValue(forKey: key)
        return artifact(
            from: descriptor,
            audioIdentity: active.request.finalAudioIdentity
        )
    }

    public func discardPartial(attemptID: SynthesisAttemptID) async {
        guard let active = activeWrites.removeValue(
            forKey: attemptID.rawValue
        ) else {
            return
        }
        await store.discard(active.token)
    }

    public func recoverFinalizedAudio(
        _ request: InterviewerSpeechAudioRecoveryRequest
    ) async throws -> InterviewerSpeechAudioArtifact? {
        guard let descriptor = try await store.recover(
            sessionIdentity: request.sessionID.rawValue,
            attemptIdentity: request.attemptID.rawValue,
            partialFileName: request.partialAudioIdentity.fileName,
            finalFileName: request.finalAudioIdentity.fileName
        ) else {
            return nil
        }
        return artifact(
            from: descriptor,
            audioIdentity: request.finalAudioIdentity
        )
    }

    public func validateAudio(
        sessionID: SessionID,
        artifact: InterviewerSpeechAudioArtifact
    ) async -> Bool {
        do {
            let descriptor = try await store.inspectFinal(
                sessionIdentity: sessionID.rawValue,
                fileName: artifact.audioIdentity.fileName
            )
            return matches(descriptor, artifact: artifact)
        } catch {
            return false
        }
    }

    func playbackURL(
        sessionID: SessionID,
        artifact: InterviewerSpeechAudioArtifact
    ) async throws -> URL {
        let validated = try await store.inspectFinalForPlayback(
            sessionIdentity: sessionID.rawValue,
            fileName: artifact.audioIdentity.fileName
        )
        guard matches(validated.descriptor, artifact: artifact) else {
            throw PrivateInterviewerWaveStoreError.invalidFinalFile
        }
        return validated.url
    }

    private func artifact(
        from descriptor: PrivateInterviewerWaveDescriptor,
        audioIdentity: InterviewerAudioIdentity
    ) -> InterviewerSpeechAudioArtifact {
        InterviewerSpeechAudioArtifact(
            audioIdentity: audioIdentity,
            sampleRate: descriptor.sampleRate,
            channelCount: descriptor.channelCount,
            durationMilliseconds: Int64(descriptor.durationMilliseconds),
            byteCount: Int64(descriptor.byteCount),
            sha256: descriptor.sha256
        )
    }

    private func matches(
        _ descriptor: PrivateInterviewerWaveDescriptor,
        artifact: InterviewerSpeechAudioArtifact
    ) -> Bool {
        descriptor.fileName == artifact.audioIdentity.fileName
            && descriptor.sampleRate == artifact.sampleRate
            && descriptor.channelCount == artifact.channelCount
            && Int64(descriptor.durationMilliseconds) == artifact.durationMilliseconds
            && Int64(descriptor.byteCount) == artifact.byteCount
            && descriptor.sha256 == artifact.sha256
    }
}
