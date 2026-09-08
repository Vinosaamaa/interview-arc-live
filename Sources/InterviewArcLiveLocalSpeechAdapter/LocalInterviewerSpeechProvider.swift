import Foundation
import InterviewArcLiveCore
import MLXAudioCore
import MLXAudioTTS

public enum LocalInterviewerSpeechError: String, Error, Sendable, Equatable {
    case notPrepared
    case invalidRequest
    case profileMismatch
    case generationInProgress
    case invalidAudio
    case incompatibleRuntime
    case generationFailed
    case cancelled
}

protocol LocalSpeechModelLoading: Sendable {
    func loadModel(from directory: URL) async throws -> any LocalStreamingSpeechModel
}

protocol LocalStreamingSpeechModel: Sendable {
    var sampleRate: Int { get }

    func startGeneration(
        text: String,
        profile: InterviewerSpeechProfile
    ) -> any LocalSpeechGeneration
}

/// Joinable, single-consumer generation Seam. The production implementation
/// iterates the upstream Qwen handle directly so cancellation can await the
/// actual MLX producer instead of an unjoinable proxy stream.
protocol LocalSpeechGeneration: Sendable {
    func nextSamples() async throws -> [Float]?
    func cancelAndWait() async
}

/// Production Adapter at the Core interviewer-speech Seam. A model is usable
/// for synthesis only after this process has completed the store's full hash,
/// staged-loader, promoted-path reload, and derived-tokenizer gates.
public actor LocalInterviewerSpeechProvider: InterviewerSpeechProvider {
    public nonisolated let provenance: InterviewerSpeechProvenance

    private let store: LocalSpeechModelStore
    private let loader: any LocalSpeechModelLoading
    private var loadedModel: (any LocalStreamingSpeechModel)?
    private var isPreparing = false
    private var activePreparationID: UUID?
    private var latestPreparationProgress: InterviewerSpeechPreparationProgress?
    private var activeGenerationID: UUID?
    private var activeGenerationTask: Task<Void, Never>?
    private var isCancellingSynthesis = false
    private var lastOutputBufferHighWaterMark = 0

    /// Derives the Live-owned Application Support model root internally. The
    /// app never supplies or persists a provider-specific filesystem path.
    public init(engine: LocalSpeechEngine = .qwen) throws {
        let applicationSupportRoot = try LivePaths.applicationSupportRoot()
        let modelRoot = applicationSupportRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(engine == .qwen ? "Qwen3TTS" : "Kokoro", isDirectory: true)
        provenance = engine.provenance
        store = LocalSpeechModelStore(
            modelRoot: modelRoot,
            privateStorageRoot: applicationSupportRoot,
            manifest: engine == .qwen ? Qwen3TTSProvenance.publicSnapshot : KokoroProvenance.publicSnapshot,
            downloader: engine == .qwen
                ? HuggingFaceLocalSpeechSnapshotDownloader()
                : KokoroSnapshotDownloader(),
            minimumFreeBytes: engine.minimumFreeByteCount,
            derivesTokenizer: engine == .qwen
        )
        loader = engine == .qwen ? MLXQwenSpeechModelLoader() : MLXKokoroSpeechModelLoader()
    }

    init(
        store: LocalSpeechModelStore,
        loader: any LocalSpeechModelLoading,
        provenance: InterviewerSpeechProvenance = LocalSpeechEngine.qwen.provenance
    ) {
        self.provenance = provenance
        self.store = store
        self.loader = loader
    }

    public func readiness() async -> InterviewerSpeechReadiness {
        if isPreparing {
            return .preparing(
                latestPreparationProgress ?? Self.progress(
                    stage: .checkingStorage,
                    completedBytes: 0,
                    totalBytes: store.snapshotByteCount
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
                    completedBytes: 0,
                    totalBytes: store.snapshotByteCount
                )
            )
        }
        if loadedModel != nil, case .ready = await store.readiness() {
            return .ready
        }

        isPreparing = true
        let preparationID = UUID()
        activePreparationID = preparationID
        let checking = Self.progress(
            stage: .checkingStorage,
            completedBytes: 0,
            totalBytes: store.snapshotByteCount
        )
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
                        throw LocalInterviewerSpeechError.incompatibleRuntime
                    }
                    // Deliberately discard the staging-loaded object. The store
                    // promotes only after this succeeds and the provider then
                    // reloads from the final directory.
                },
                loadPromoted: { directory in
                    let model = try await loader.loadModel(from: directory)
                    guard model.sampleRate == Self.requiredSampleRate else {
                        throw LocalInterviewerSpeechError.incompatibleRuntime
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
        } catch let failure as LocalSpeechModelStoreFailure {
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
            throw LocalInterviewerSpeechError.generationInProgress
        }
        guard request.profile == provenance.profile else {
            throw LocalInterviewerSpeechError.profileMismatch
        }
        guard !request.spokenText.isEmpty,
              !request.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalInterviewerSpeechError.invalidRequest
        }
        guard let model = loadedModel else {
            throw LocalInterviewerSpeechError.notPrepared
        }
        guard model.sampleRate == Self.requiredSampleRate else {
            throw LocalInterviewerSpeechError.incompatibleRuntime
        }

        let generation = model.startGeneration(
            text: request.spokenText,
            profile: request.profile
        )
        let generationID = UUID()
        let channel = LocalBoundedSpeechEventChannel(capacity: Self.outputBufferCapacity)
        let cancellationRelay = LocalGenerationCancellationRelay()
        let stream = AsyncThrowingStream<InterviewerSpeechEvent, Error>(unfolding: {
            try await withTaskCancellationHandler {
                try await channel.next()
            } onCancel: {
                cancellationRelay.cancel()
            }
        })
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
                while let samples = try await generation.nextSamples() {
                    try Task.checkCancellation()
                    guard !samples.isEmpty,
                          samples.count <= Self.maximumChunkSampleCount,
                          samples.allSatisfy(\.isFinite) else {
                        throw LocalInterviewerSpeechError.invalidAudio
                    }
                    if firstAudioMilliseconds == nil {
                        firstAudioMilliseconds = Self.elapsedMilliseconds(since: started)
                    }
                    chunkCount += 1
                    let (nextCount, overflow) = sampleCount.addingReportingOverflow(samples.count)
                    guard !overflow else {
                        throw LocalInterviewerSpeechError.invalidAudio
                    }
                    guard nextCount <= Self.maximumGeneratedSampleCount else {
                        throw LocalInterviewerSpeechError.invalidAudio
                    }
                    sampleCount = nextCount
                    try await channel.send(
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
                    throw LocalInterviewerSpeechError.invalidAudio
                }
                try await channel.send(
                    .completed(
                        InterviewerSpeechGenerationMetrics(
                            chunkCount: chunkCount,
                            generatedSampleCount: sampleCount,
                            timeToFirstAudioMilliseconds: firstAudioMilliseconds,
                            totalGenerationMilliseconds: Self.elapsedMilliseconds(since: started)
                        )
                    )
                )
                let highWaterMark = await channel.highWaterMark()
                await self?.generationDidFinish(
                    generationID,
                    outputBufferHighWaterMark: highWaterMark
                )
                await channel.finish()
            } catch is CancellationError {
                await generation.cancelAndWait()
                let highWaterMark = await channel.highWaterMark()
                await self?.generationDidFinish(
                    generationID,
                    outputBufferHighWaterMark: highWaterMark
                )
                await channel.finish(throwing: .cancelled)
            } catch let error as LocalInterviewerSpeechError {
                await generation.cancelAndWait()
                let highWaterMark = await channel.highWaterMark()
                await self?.generationDidFinish(
                    generationID,
                    outputBufferHighWaterMark: highWaterMark
                )
                await channel.finish(throwing: error)
            } catch {
                await generation.cancelAndWait()
                let failure: LocalInterviewerSpeechError = Task.isCancelled
                    ? .cancelled
                    : .generationFailed
                let highWaterMark = await channel.highWaterMark()
                await self?.generationDidFinish(
                    generationID,
                    outputBufferHighWaterMark: highWaterMark
                )
                await channel.finish(throwing: failure)
            }
        }
        cancellationRelay.register(task)
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
        } catch let failure as LocalSpeechModelStoreFailure {
            return .unavailable(Self.mapFailure(failure))
        } catch {
            return .unavailable(.storageFailure)
        }
    }

    private func generationDidFinish(
        _ generationID: UUID,
        outputBufferHighWaterMark: Int
    ) {
        guard activeGenerationID == generationID else { return }
        lastOutputBufferHighWaterMark = outputBufferHighWaterMark
        activeGenerationID = nil
        activeGenerationTask = nil
    }

    func outputBufferHighWaterMark() -> Int {
        lastOutputBufferHighWaterMark
    }

    private func recordPreparationProgress(
        _ progress: InterviewerSpeechPreparationProgress,
        preparationID: UUID
    ) {
        guard isPreparing, activePreparationID == preparationID else { return }
        latestPreparationProgress = progress
    }

    private static let requiredSampleRate = 24_000
    static let outputBufferCapacity = 8
    static let maximumChunkSampleCount = requiredSampleRate * 5
    static let maximumGeneratedSampleCount = 2_400_000

    private static func elapsedMilliseconds(since start: UInt64) -> Int64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= start ? now - start : 0
        return Int64(min(elapsed / 1_000_000, UInt64(Int64.max)))
    }

    private static func progress(
        stage: InterviewerSpeechPreparationStage,
        completedBytes: Int64,
        totalBytes: Int64
    ) -> InterviewerSpeechPreparationProgress {
        InterviewerSpeechPreparationProgress(
            stage: stage,
            completedBytes: completedBytes,
            totalBytes: totalBytes
        )
    }

    private static func mapProgress(
        _ progress: LocalSpeechModelStoreProgress
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
        _ readiness: LocalSpeechModelStoreReadiness
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
        _ failure: LocalSpeechModelStoreFailure
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

/// One-producer bounded channel behind the public AsyncThrowingStream. `send`
/// suspends at capacity and resumes only after the consumer removes an event,
/// so valid audio is neither dropped nor retained without a fixed bound.
private actor LocalBoundedSpeechEventChannel {
    private struct PendingSend {
        let id: UUID
        let event: InterviewerSpeechEvent
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct PendingReceive {
        let id: UUID
        let continuation: CheckedContinuation<InterviewerSpeechEvent?, Error>
    }

    private enum TerminalState {
        case open
        case finished
        case failed(LocalInterviewerSpeechError)
    }

    private let capacity: Int
    private var buffer = [InterviewerSpeechEvent]()
    private var pendingSends = [PendingSend]()
    private var pendingReceives = [PendingReceive]()
    private var terminalState = TerminalState.open
    private var observedHighWaterMark = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func send(_ event: InterviewerSpeechEvent) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueSend(id: id, event: event, continuation: continuation)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelSend(id: id) }
        }
    }

    func next() async throws -> InterviewerSpeechEvent? {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueueReceive(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelReceive(id: id) }
        }
    }

    func finish(throwing failure: LocalInterviewerSpeechError? = nil) {
        guard case .open = terminalState else { return }
        terminalState = failure.map(TerminalState.failed) ?? .finished

        let sendFailure = failure ?? .generationFailed
        let sends = pendingSends
        pendingSends.removeAll()
        sends.forEach { $0.continuation.resume(throwing: sendFailure) }
        resumeTerminalReceiversIfDrained()
    }

    func highWaterMark() -> Int {
        observedHighWaterMark
    }

    private func enqueueSend(
        id: UUID,
        event: InterviewerSpeechEvent,
        continuation: CheckedContinuation<Void, Error>
    ) {
        switch terminalState {
        case .finished:
            continuation.resume(throwing: LocalInterviewerSpeechError.generationFailed)
        case .failed(let failure):
            continuation.resume(throwing: failure)
        case .open:
            if !pendingReceives.isEmpty {
                let receive = pendingReceives.removeFirst()
                receive.continuation.resume(returning: event)
                continuation.resume()
            } else if buffer.count < capacity {
                buffer.append(event)
                observedHighWaterMark = max(observedHighWaterMark, buffer.count)
                continuation.resume()
            } else {
                pendingSends.append(
                    PendingSend(id: id, event: event, continuation: continuation)
                )
            }
        }
    }

    private func enqueueReceive(
        id: UUID,
        continuation: CheckedContinuation<InterviewerSpeechEvent?, Error>
    ) {
        if !buffer.isEmpty {
            let event = buffer.removeFirst()
            admitOldestPendingSend()
            continuation.resume(returning: event)
            return
        }
        if !pendingSends.isEmpty {
            let send = pendingSends.removeFirst()
            send.continuation.resume()
            continuation.resume(returning: send.event)
            return
        }

        switch terminalState {
        case .open:
            pendingReceives.append(PendingReceive(id: id, continuation: continuation))
        case .finished:
            continuation.resume(returning: nil)
        case .failed(let failure):
            continuation.resume(throwing: failure)
        }
    }

    private func admitOldestPendingSend() {
        guard !pendingSends.isEmpty else { return }
        let send = pendingSends.removeFirst()
        buffer.append(send.event)
        observedHighWaterMark = max(observedHighWaterMark, buffer.count)
        send.continuation.resume()
    }

    private func cancelSend(id: UUID) {
        guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
        let send = pendingSends.remove(at: index)
        send.continuation.resume(throwing: CancellationError())
    }

    private func cancelReceive(id: UUID) {
        guard let index = pendingReceives.firstIndex(where: { $0.id == id }) else { return }
        let receive = pendingReceives.remove(at: index)
        receive.continuation.resume(throwing: CancellationError())
    }

    private func resumeTerminalReceiversIfDrained() {
        guard buffer.isEmpty, pendingSends.isEmpty else { return }
        let receives = pendingReceives
        pendingReceives.removeAll()
        switch terminalState {
        case .open:
            return
        case .finished:
            receives.forEach { $0.continuation.resume(returning: nil) }
        case .failed(let failure):
            receives.forEach { $0.continuation.resume(throwing: failure) }
        }
    }
}

/// The unfolding stream has no throwing `onCancel` overload. This relay keeps
/// cancellation/deinitialization connected to the registered producer Task.
private final class LocalGenerationCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationRequested = false

    func register(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancellationRequested
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancellationRequested = true
            return self.task
        }
        task?.cancel()
    }

    deinit {
        cancel()
    }
}

struct MLXQwenSpeechModelLoader: LocalSpeechModelLoading {
    func loadModel(from directory: URL) async throws -> any LocalStreamingSpeechModel {
        let model = try await Qwen3TTSModel.fromModelDirectory(directory)
        guard model.sampleRate == 24_000 else {
            throw LocalInterviewerSpeechError.incompatibleRuntime
        }
        return MLXLocalStreamingSpeechModel(model: model)
    }
}

final class MLXLocalStreamingSpeechModel: LocalStreamingSpeechModel, @unchecked Sendable {
    let sampleRate: Int
    private let model: Qwen3TTSModel

    init(model: Qwen3TTSModel) {
        self.model = model
        sampleRate = model.sampleRate
    }

    func startGeneration(
        text: String,
        profile: InterviewerSpeechProfile
    ) -> any LocalSpeechGeneration {
        let resolved = QwenResolvedGenerationOptions(profile: profile)
        var parameters = model.defaultGenerationParameters
        parameters.maxTokens = resolved.maxTokens
        parameters.temperature = resolved.temperature
        parameters.topP = resolved.topP
        parameters.topK = resolved.topK
        parameters.minP = resolved.minP
        parameters.repetitionPenalty = resolved.repetitionPenalty
        parameters.repetitionContextSize = resolved.repetitionContextSize

        let handle = model.generateStreamHandle(
            text: text,
            voice: resolved.conditioning,
            refAudio: nil,
            refText: nil,
            language: resolved.language,
            generationParameters: parameters,
            streamingInterval: resolved.streamingInterval
        )
        return MLXLocalSpeechGeneration(handle: handle)
    }
}

/// The handle is consumed by exactly one provider Task. Keeping the upstream
/// iterator here avoids the library's `generateSamplesStream` proxy and retains
/// the true producer handle needed for cancellation joins.
private final class MLXLocalSpeechGeneration: LocalSpeechGeneration, @unchecked Sendable {
    private let handle: Qwen3TTSGenerationHandle
    private var iterator: AsyncThrowingStream<AudioGeneration, Error>.Iterator

    init(handle: Qwen3TTSGenerationHandle) {
        self.handle = handle
        iterator = handle.stream.makeAsyncIterator()
    }

    func nextSamples() async throws -> [Float]? {
        while let event = try await iterator.next() {
            guard case .audio(let samples) = event else { continue }
            return samples.asArray(Float.self)
        }
        return nil
    }

    func cancelAndWait() async {
        await handle.cancelAndWait()
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
