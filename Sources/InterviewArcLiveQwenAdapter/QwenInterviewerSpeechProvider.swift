import Foundation
import InterviewArcLiveCore
import MLXAudioCore
import MLXAudioTTS

public enum QwenInterviewerSpeechError: String, Error, Sendable, Equatable {
    case notPrepared
    case invalidRequest
    case profileMismatch
    case generationInProgress
    case invalidAudio
    case incompatibleRuntime
    case generationFailed
    case cancelled
}

protocol QwenSpeechModelLoading: Sendable {
    func loadModel(from directory: URL) async throws -> any QwenStreamingSpeechModel
}

protocol QwenStreamingSpeechModel: Sendable {
    var sampleRate: Int { get }

    func generateSamples(
        text: String,
        profile: InterviewerSpeechProfile
    ) -> AsyncThrowingStream<[Float], Error>
}

/// Production Adapter at the Core interviewer-speech Seam. A model is usable
/// for synthesis only after this process has completed the store's full hash,
/// staged-loader, promoted-path reload, and derived-tokenizer gates.
public actor QwenInterviewerSpeechProvider: InterviewerSpeechProvider {
    public nonisolated let provenance = InterviewerSpeechProvenance(
        providerID: Qwen3TTSProvenance.providerID,
        modelID: Qwen3TTSProvenance.modelID,
        modelRevision: Qwen3TTSProvenance.modelRevision,
        profile: .maraV1
    )

    private let store: QwenModelStore
    private let loader: any QwenSpeechModelLoading
    private var loadedModel: (any QwenStreamingSpeechModel)?
    private var isPreparing = false
    private var activePreparationID: UUID?
    private var latestPreparationProgress: InterviewerSpeechPreparationProgress?
    private var activeGenerationID: UUID?
    private var activeGenerationTask: Task<Void, Never>?
    private var isCancellingSynthesis = false

    /// Derives the Live-owned Application Support model root internally. The
    /// app never supplies or persists a provider-specific filesystem path.
    public init() throws {
        let applicationSupportRoot = try LivePaths.applicationSupportRoot()
        let modelRoot = applicationSupportRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Qwen3TTS", isDirectory: true)
        store = QwenModelStore(
            modelRoot: modelRoot,
            privateStorageRoot: applicationSupportRoot
        )
        loader = MLXQwenSpeechModelLoader()
    }

    init(
        store: QwenModelStore,
        loader: any QwenSpeechModelLoading
    ) {
        self.store = store
        self.loader = loader
    }

    public func readiness() async -> InterviewerSpeechReadiness {
        if isPreparing {
            return .preparing(
                latestPreparationProgress ?? Self.progress(
                    stage: .checkingStorage,
                    completedBytes: 0
                )
            )
        }
        return Self.mapReadiness(await store.readiness())
    }

    public func prepare(
        _ policy: InterviewerSpeechPreparationPolicy,
        progress: @escaping @Sendable (InterviewerSpeechPreparationProgress) -> Void
    ) async throws -> InterviewerSpeechReadiness {
        if isPreparing {
            return .preparing(
                latestPreparationProgress ?? Self.progress(
                    stage: .checkingStorage,
                    completedBytes: 0
                )
            )
        }
        if loadedModel != nil, case .ready = await store.readiness() {
            return .ready
        }

        isPreparing = true
        let preparationID = UUID()
        activePreparationID = preparationID
        let checking = Self.progress(stage: .checkingStorage, completedBytes: 0)
        latestPreparationProgress = checking
        progress(checking)
        defer {
            if activePreparationID == preparationID {
                activePreparationID = nil
                isPreparing = false
                latestPreparationProgress = nil
            }
        }

        let loader = loader
        do {
            let prepared = try await store.prepare(
                allowDownload: policy == .userAuthorizedDownload,
                validateStagedLoad: { directory in
                    let model = try await loader.loadModel(from: directory)
                    guard model.sampleRate == Self.requiredSampleRate else {
                        throw QwenInterviewerSpeechError.incompatibleRuntime
                    }
                    // Deliberately discard the staging-loaded object. The store
                    // promotes only after this succeeds and the provider then
                    // reloads from the final directory.
                },
                loadPromoted: { directory in
                    let model = try await loader.loadModel(from: directory)
                    guard model.sampleRate == Self.requiredSampleRate else {
                        throw QwenInterviewerSpeechError.incompatibleRuntime
                    }
                    return model
                },
                progress: { [weak self] update in
                    let mapped = Self.mapProgress(update)
                    Task {
                        await self?.recordPreparationProgress(
                            mapped,
                            preparationID: preparationID
                        )
                    }
                    progress(mapped)
                }
            )
            loadedModel = prepared.loadedModel
            return .ready
        } catch let failure as QwenModelStoreFailure {
            if failure == .missingFile, policy == .neverDownload {
                return .notInstalled
            }
            return .unavailable(Self.mapFailure(failure))
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch {
            return .unavailable(.incompatibleRuntime)
        }
    }

    public func synthesize(
        _ request: InterviewerSpeechSynthesisRequest
    ) async throws -> AsyncThrowingStream<InterviewerSpeechEvent, Error> {
        guard activeGenerationTask == nil, !isCancellingSynthesis else {
            throw QwenInterviewerSpeechError.generationInProgress
        }
        guard request.profile == provenance.profile else {
            throw QwenInterviewerSpeechError.profileMismatch
        }
        guard !request.spokenText.isEmpty,
              !request.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QwenInterviewerSpeechError.invalidRequest
        }
        guard let model = loadedModel else {
            throw QwenInterviewerSpeechError.notPrepared
        }
        guard model.sampleRate == Self.requiredSampleRate else {
            throw QwenInterviewerSpeechError.incompatibleRuntime
        }

        let upstream = model.generateSamples(text: request.spokenText, profile: request.profile)
        let generationID = UUID()
        let (stream, continuation) = AsyncThrowingStream<InterviewerSpeechEvent, Error>.makeStream()
        // Register single-flight ownership before even a synchronous fixture
        // stream can finish. This keeps terminal cleanup from racing the
        // assignment below and stranding a completed Task as active.
        let (startSignal, startContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            var firstAudioMilliseconds: Int64?
            var chunkCount = 0
            var sampleCount = 0
            do {
                var startIterator = startSignal.makeAsyncIterator()
                guard await startIterator.next() != nil else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                for try await samples in upstream {
                    try Task.checkCancellation()
                    guard !samples.isEmpty,
                          samples.allSatisfy(\.isFinite) else {
                        throw QwenInterviewerSpeechError.invalidAudio
                    }
                    if firstAudioMilliseconds == nil {
                        firstAudioMilliseconds = Self.elapsedMilliseconds(since: started)
                    }
                    chunkCount += 1
                    let (nextCount, overflow) = sampleCount.addingReportingOverflow(samples.count)
                    guard !overflow else {
                        throw QwenInterviewerSpeechError.invalidAudio
                    }
                    sampleCount = nextCount
                    continuation.yield(
                        .pcm(
                            InterviewerSpeechPCMChunk(
                                samples: samples,
                                sampleRate: Self.requiredSampleRate,
                                channelCount: 1
                            )
                        )
                    )
                }
                try Task.checkCancellation()
                guard chunkCount > 0, sampleCount > 0 else {
                    throw QwenInterviewerSpeechError.invalidAudio
                }
                continuation.yield(
                    .completed(
                        InterviewerSpeechGenerationMetrics(
                            chunkCount: chunkCount,
                            generatedSampleCount: sampleCount,
                            timeToFirstAudioMilliseconds: firstAudioMilliseconds,
                            totalGenerationMilliseconds: Self.elapsedMilliseconds(since: started)
                        )
                    )
                )
                await self?.generationDidFinish(generationID)
                continuation.finish()
            } catch is CancellationError {
                await self?.generationDidFinish(generationID)
                continuation.finish(throwing: QwenInterviewerSpeechError.cancelled)
            } catch let error as QwenInterviewerSpeechError {
                await self?.generationDidFinish(generationID)
                continuation.finish(throwing: error)
            } catch {
                await self?.generationDidFinish(generationID)
                continuation.finish(
                    throwing: Task.isCancelled
                        ? QwenInterviewerSpeechError.cancelled
                        : QwenInterviewerSpeechError.generationFailed
                )
            }
        }
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }
        activeGenerationID = generationID
        activeGenerationTask = task
        startContinuation.yield(())
        startContinuation.finish()
        return stream
    }

    public func cancelSynthesis() async {
        guard !isCancellingSynthesis else {
            await activeGenerationTask?.value
            return
        }
        isCancellingSynthesis = true
        let generationID = activeGenerationID
        let task = activeGenerationTask
        task?.cancel()
        if let task {
            await task.value
        }
        if activeGenerationID == generationID {
            activeGenerationTask = nil
            activeGenerationID = nil
        }
        isCancellingSynthesis = false
    }

    public func unload() async {
        await cancelSynthesis()
        loadedModel = nil
    }

    public func removePreparedModel() async throws -> InterviewerSpeechReadiness {
        await unload()
        do {
            try await store.removeInstalledRevision()
            return .notInstalled
        } catch let failure as QwenModelStoreFailure {
            return .unavailable(Self.mapFailure(failure))
        } catch {
            return .unavailable(.storageFailure)
        }
    }

    private func generationDidFinish(_ generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        activeGenerationID = nil
        activeGenerationTask = nil
    }

    private func recordPreparationProgress(
        _ progress: InterviewerSpeechPreparationProgress,
        preparationID: UUID
    ) {
        guard isPreparing, activePreparationID == preparationID else { return }
        latestPreparationProgress = progress
    }

    private static let requiredSampleRate = 24_000

    private static func elapsedMilliseconds(since start: UInt64) -> Int64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= start ? now - start : 0
        return Int64(min(elapsed / 1_000_000, UInt64(Int64.max)))
    }

    private static func progress(
        stage: InterviewerSpeechPreparationStage,
        completedBytes: Int64
    ) -> InterviewerSpeechPreparationProgress {
        InterviewerSpeechPreparationProgress(
            stage: stage,
            completedBytes: completedBytes,
            totalBytes: Qwen3TTSProvenance.snapshotByteCount
        )
    }

    private static func mapProgress(
        _ progress: QwenModelStoreProgress
    ) -> InterviewerSpeechPreparationProgress {
        let stage: InterviewerSpeechPreparationStage = switch progress.stage {
        case .checkingStorage: .checkingStorage
        case .downloading: .downloading
        case .verifying: .verifying
        case .promoting: .promoting
        }
        return InterviewerSpeechPreparationProgress(
            stage: stage,
            completedBytes: progress.completedBytes,
            totalBytes: progress.totalBytes
        )
    }

    private static func mapReadiness(
        _ readiness: QwenModelStoreReadiness
    ) -> InterviewerSpeechReadiness {
        switch readiness {
        case .notInstalled:
            return .notInstalled
        case .preparing(let progress):
            return .preparing(mapProgress(progress))
        case .ready:
            return .ready
        case .unavailable(let failure):
            return .unavailable(mapFailure(failure))
        }
    }

    private static func mapFailure(
        _ failure: QwenModelStoreFailure
    ) -> InterviewerSpeechReadinessFailure {
        switch failure {
        case .insufficientFreeSpace:
            return .insufficientStorage
        case .downloadFailed:
            return .networkUnavailable
        case .cancelled:
            return .cancelled
        case .invalidSnapshotRoot,
             .symbolicLinkRejected,
             .unexpectedSnapshotShape,
             .missingFile,
             .wrongFileSize,
             .hashMismatch,
             .invalidVerificationReceipt,
             .derivedTokenizerInvalid:
            return .verificationFailed
        case .loaderValidationFailed:
            return .incompatibleRuntime
        case .invalidStorageRoot,
             .preparationInProgress,
             .storageFailure:
            return .storageFailure
        }
    }
}

struct MLXQwenSpeechModelLoader: QwenSpeechModelLoading {
    func loadModel(from directory: URL) async throws -> any QwenStreamingSpeechModel {
        let model = try await Qwen3TTSModel.fromModelDirectory(directory)
        guard model.sampleRate == 24_000 else {
            throw QwenInterviewerSpeechError.incompatibleRuntime
        }
        return MLXQwenStreamingSpeechModel(model: model)
    }
}

final class MLXQwenStreamingSpeechModel: QwenStreamingSpeechModel, @unchecked Sendable {
    let sampleRate: Int
    private let model: Qwen3TTSModel

    init(model: Qwen3TTSModel) {
        self.model = model
        sampleRate = model.sampleRate
    }

    func generateSamples(
        text: String,
        profile: InterviewerSpeechProfile
    ) -> AsyncThrowingStream<[Float], Error> {
        let resolved = QwenResolvedGenerationOptions(profile: profile)
        var parameters = model.defaultGenerationParameters
        parameters.maxTokens = resolved.maxTokens
        parameters.temperature = resolved.temperature
        parameters.topP = resolved.topP
        parameters.topK = resolved.topK
        parameters.minP = resolved.minP
        parameters.repetitionPenalty = resolved.repetitionPenalty
        parameters.repetitionContextSize = resolved.repetitionContextSize

        return model.generateSamplesStream(
            text: text,
            voice: resolved.conditioning,
            refAudio: nil,
            refText: nil,
            language: resolved.language,
            generationParameters: parameters,
            streamingInterval: resolved.streamingInterval
        )
    }
}

struct QwenResolvedGenerationOptions: Equatable, Sendable {
    let language: String
    let conditioning: String
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let topK: Int
    let minP: Float
    let repetitionPenalty: Float
    let repetitionContextSize: Int
    let streamingInterval: Double

    init(profile: InterviewerSpeechProfile) {
        language = profile.language
        conditioning = profile.conditioning
        maxTokens = profile.maxTokens
        temperature = Float(profile.temperature)
        topP = Float(profile.topP)
        topK = profile.topK
        minP = Float(profile.minP)
        repetitionPenalty = Float(profile.repetitionPenalty)
        repetitionContextSize = profile.repetitionContextSize
        streamingInterval = profile.streamingInterval
    }
}
