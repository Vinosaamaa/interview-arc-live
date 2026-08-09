import CryptoKit
import Darwin
import Foundation
import InterviewArcLiveCore
import InterviewArcLiveQwenAdapter
import InterviewArcLiveSpeechOutputAdapter

@main
struct InterviewArcLiveSpeechSmoke {
    private static let spokenText =
        "Let's clarify the requirements before we choose an architecture."

    static func main() async {
        guard ProcessInfo.processInfo.environment[
            "INTERVIEW_ARC_LIVE_RUN_SPEECH_SMOKE"
        ] == "1" else {
            fail("Installed local-speech smoke is not authorized.", code: 64)
        }

        let fileManager = FileManager.default
        let smokeRoot = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        guard isSafeSmokeRoot(smokeRoot, fileManager: fileManager) else {
            fail("Installed local-speech smoke requires its verified isolated workspace.", code: 65)
        }

        do {
            let result = try await run(smokeRoot: smokeRoot)
            try removeSmokeAudio(smokeRoot: smokeRoot, fileManager: fileManager)
            let firstAudio = result.metrics.timeToFirstAudioMilliseconds
                .map(String.init) ?? "unknown"
            let totalGeneration = result.metrics.totalGenerationMilliseconds
                .map(String.init) ?? "unknown"
            print("model_revision=\(Qwen3TTSProvenance.modelRevision)")
            print("chunk_count=\(result.metrics.chunkCount)")
            print("time_to_first_audio_ms=\(firstAudio)")
            print("generation_total_ms=\(totalGeneration)")
            print("audio_duration_ms=\(result.artifact.durationMilliseconds)")
            print("audio_bytes=\(result.artifact.byteCount)")
        } catch let failure as SmokeFailure {
            try? removeSmokeAudio(smokeRoot: smokeRoot, fileManager: fileManager)
            fail(failure.message, code: failure.exitCode)
        } catch {
            try? removeSmokeAudio(smokeRoot: smokeRoot, fileManager: fileManager)
            fail(
                "Installed local-speech smoke failed without exposing private provider data.",
                code: 1
            )
        }
    }

    private static func run(
        smokeRoot: URL
    ) async throws -> SmokeResult {
        let provider = try QwenInterviewerSpeechProvider()
        let initial = await provider.readiness()
        let permitsDownload = ProcessInfo.processInfo.environment[
            "INTERVIEW_ARC_LIVE_ALLOW_MODEL_DOWNLOAD"
        ] == "1"
        let policy: InterviewerSpeechPreparationPolicy
        switch initial {
        case .notInstalled:
            guard permitsDownload else {
                throw SmokeFailure(
                    message: "The pinned local voice is absent. Set INTERVIEW_ARC_LIVE_ALLOW_MODEL_DOWNLOAD=1 to authorize the 1.838 GiB transfer.",
                    exitCode: 69
                )
            }
            policy = .userAuthorizedDownload
        case .unavailable:
            guard permitsDownload else {
                throw SmokeFailure(
                    message: "The pinned local voice is not ready. Explicit model-download authorization is required for repair.",
                    exitCode: 69
                )
            }
            policy = .userAuthorizedDownload
        case .preparing:
            throw SmokeFailure(
                message: "Another local voice preparation is already running.",
                exitCode: 75
            )
        case .ready:
            policy = .neverDownload
        }

        let prepared = try await provider.prepare(policy) { _ in }
        guard prepared == .ready else {
            throw SmokeFailure(
                message: "The exact local voice did not become ready.",
                exitCode: 69
            )
        }

        let sessionID = SessionID("installed-local-speech-smoke")
        let utteranceID = InterviewerUtteranceID("installed-local-speech-smoke-utterance")
        let attemptID = SynthesisAttemptID("installed-local-speech-smoke-attempt")
        let digest = SHA256.hash(data: Data(attemptID.rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let partial = try InterviewerAudioIdentity(
            validating: "speech-\(digest).partial.wav"
        )
        let final = try InterviewerAudioIdentity(
            validating: "speech-\(digest).wav"
        )
        let audioStore = try LiveInterviewerSpeechAudioStore(
            validatingTemporarySmokeRoot: smokeRoot
        )
        let writeRequest = InterviewerSpeechAudioWriteRequest(
            sessionID: sessionID,
            utteranceID: utteranceID,
            attemptID: attemptID,
            partialAudioIdentity: partial,
            finalAudioIdentity: final
        )
        let synthesisRequest = InterviewerSpeechSynthesisRequest(
            sessionID: sessionID,
            turnID: TurnID("installed-local-speech-smoke-turn"),
            utteranceID: utteranceID,
            attemptID: attemptID,
            spokenText: spokenText,
            profile: .maraV1
        )
        do {
            try await audioStore.beginWrite(writeRequest)
            var completion: InterviewerSpeechGenerationMetrics?
            let stream = try await provider.synthesize(synthesisRequest)
            for try await event in stream {
                switch event {
                case .pcm(let chunk):
                    guard chunk.sampleRate == 24_000,
                          chunk.channelCount == 1,
                          !chunk.samples.isEmpty,
                          chunk.samples.allSatisfy(\.isFinite) else {
                        throw SmokeFailure(
                            message: "The local model emitted invalid PCM.",
                            exitCode: 65
                        )
                    }
                    try await audioStore.append(chunk, attemptID: attemptID)
                case .completed(let metrics):
                    guard completion == nil else {
                        throw SmokeFailure(
                            message: "The local model emitted duplicate completion metadata.",
                            exitCode: 65
                        )
                    }
                    completion = metrics
                }
            }
            guard let metrics = completion,
                  metrics.chunkCount > 0,
                  metrics.generatedSampleCount > 0,
                  metrics.generatedSampleCount <= 2_400_000 else {
                throw SmokeFailure(
                    message: "The local model produced no complete bounded audio.",
                    exitCode: 65
                )
            }
            let expectedByteCount = Int64(44 + metrics.generatedSampleCount * 4)
            let expectedDuration = Int64(
                (Double(metrics.generatedSampleCount) / 24_000 * 1_000).rounded()
            )
            let artifact = try await audioStore.finalizeWrite(attemptID: attemptID)
            guard artifact.sampleRate == 24_000,
                  artifact.channelCount == 1,
                  artifact.durationMilliseconds >= 1_000,
                  artifact.durationMilliseconds == expectedDuration,
                  artifact.byteCount == expectedByteCount,
                  await audioStore.validateAudio(
                      sessionID: sessionID,
                      artifact: artifact
                  ) else {
                throw SmokeFailure(
                    message: "The finalized local WAV did not validate.",
                    exitCode: 65
                )
            }

            let player = await AVAudioEngineInterviewerSpeechPlayer(
                audioStore: audioStore
            )
            let playback = Task { @MainActor in
                try await player.play(
                    InterviewerSpeechPlaybackRequest(
                        sessionID: sessionID,
                        artifact: artifact
                    )
                )
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                await player.stop()
                do {
                    try await playback.value
                    throw SmokeFailure(
                        message: "The local playback completed before Stop could be verified.",
                        exitCode: 65
                    )
                } catch is CancellationError {
                    // Expected: the installed smoke deliberately verifies Stop.
                }
            } catch {
                playback.cancel()
                await player.stop()
                _ = try? await playback.value
                throw error
            }
            await provider.unload()
            return SmokeResult(artifact: artifact, metrics: metrics)
        } catch {
            await audioStore.discardPartial(attemptID: attemptID)
            await provider.unload()
            throw error
        }
    }

    private static func isSafeSmokeRoot(
        _ root: URL,
        fileManager: FileManager
    ) -> Bool {
        let temporary = fileManager.temporaryDirectory.standardizedFileURL
        let standardized = root.standardizedFileURL
        let name = standardized.lastPathComponent
        let hyphenPrefix = "interview-arc-live-speech-smoke-"
        let wrapperPrefix = "interview-arc-live-speech-smoke."
        return standardized.deletingLastPathComponent() == temporary
            && ((name.hasPrefix(hyphenPrefix) && name.count > hyphenPrefix.count)
                || (name.hasPrefix(wrapperPrefix) && name.count > wrapperPrefix.count))
    }

    private static func removeSmokeAudio(
        smokeRoot root: URL,
        fileManager: FileManager
    ) throws {
        guard isSafeSmokeRoot(root, fileManager: fileManager) else {
            throw SmokeFailure(
                message: "Installed local-speech smoke cleanup was not confined.",
                exitCode: 65
            )
        }
        let audioRoot = root.appendingPathComponent(
            "InterviewerSpeech",
            isDirectory: true
        ).standardizedFileURL
        guard audioRoot.deletingLastPathComponent() == root.standardizedFileURL else {
            throw SmokeFailure(
                message: "Installed local-speech smoke audio cleanup was not confined.",
                exitCode: 65
            )
        }
        if fileManager.fileExists(atPath: audioRoot.path) {
            try fileManager.removeItem(at: audioRoot)
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
        Darwin.exit(code)
    }
}

private struct SmokeResult {
    let artifact: InterviewerSpeechAudioArtifact
    let metrics: InterviewerSpeechGenerationMetrics
}

private struct SmokeFailure: Error {
    let message: String
    let exitCode: Int32
}
