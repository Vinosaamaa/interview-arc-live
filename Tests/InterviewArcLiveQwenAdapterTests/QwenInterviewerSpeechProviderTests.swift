import Foundation
import InterviewArcLiveCore
import XCTest

@testable import InterviewArcLiveQwenAdapter

@MainActor
final class QwenInterviewerSpeechProviderTests: XCTestCase {
    func testMaraV1MapsEveryResolvedQwenGenerationOptionExactly() {
        let provenance = QwenInterviewerSpeechProviderFixture.publicProvenance
        let profile = provenance.profile
        let resolved = QwenResolvedGenerationOptions(profile: profile)

        XCTAssertEqual(provenance.providerID, "local-qwen3-tts")
        XCTAssertEqual(
            provenance.modelRevision,
            "049ef77fe8816b536193c0c25f9a214d17921282"
        )
        XCTAssertEqual(profile.profileID, "mara-v1")
        XCTAssertEqual(resolved.language, "English")
        XCTAssertEqual(
            resolved.conditioning,
            "Aiden, calm, precise, warm technical interviewer with natural measured delivery."
        )
        XCTAssertEqual(resolved.maxTokens, 1_200)
        XCTAssertEqual(resolved.temperature, 0.9)
        XCTAssertEqual(resolved.topP, 1.0)
        XCTAssertEqual(resolved.topK, 0)
        XCTAssertEqual(resolved.minP, 0)
        XCTAssertEqual(resolved.repetitionPenalty, 1.05)
        XCTAssertEqual(resolved.repetitionContextSize, 20)
        XCTAssertEqual(resolved.streamingInterval, 0.32)
        XCTAssertTrue(profile.fingerprint.hasPrefix("sha256:v1:"))
    }

    func testNeverDownloadDoesNotCreateStorageOrInvokeLoader() async throws {
        let fixture = try ProviderFixture.make()
        defer { fixture.remove() }

        let initialReadiness = await fixture.provider.readiness()
        let preparedReadiness = try await fixture.provider.prepare(.neverDownload) { _ in }
        let downloadCount = await fixture.downloader.callCount()
        let loadedDirectories = await fixture.loader.loadedDirectories()

        XCTAssertEqual(initialReadiness, .notInstalled)
        XCTAssertEqual(preparedReadiness, .notInstalled)
        XCTAssertEqual(downloadCount, 0)
        XCTAssertEqual(loadedDirectories.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.modelRoot.path))
    }

    func testAuthorizedPrepareLoadsInStagingThenReloadsPromotedFinal() async throws {
        let fixture = try ProviderFixture.make()
        defer { fixture.remove() }
        let progress = ProviderProgressRecorder()

        let readiness = try await fixture.provider.prepare(.userAuthorizedDownload) {
            progress.append($0)
        }

        XCTAssertEqual(readiness, .ready)
        let downloadCount = await fixture.downloader.callCount()
        XCTAssertEqual(downloadCount, 1)
        let directories = await fixture.loader.loadedDirectories()
        XCTAssertEqual(directories.count, 2)
        XCTAssertTrue(directories[0].path.contains("/staging/"))
        XCTAssertTrue(directories[1].path.hasSuffix("/snapshot"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directories[1].path))
        XCTAssertEqual(Set(progress.values.map(\.stage)), Set([
            .checkingStorage, .downloading, .verifying, .promoting,
        ]))
        XCTAssertTrue(progress.values.allSatisfy {
            $0.completedBytes >= 0
                && $0.completedBytes <= $0.totalBytes
                && $0.totalBytes == fixture.manifest.byteCount
        })
    }

    func testInstalledRelaunchPrepareNeverDownloadLoadsWithoutNetwork() async throws {
        let fixture = try ProviderFixture.make()
        defer { fixture.remove() }
        let initialPreparation = try await fixture.provider.prepare(.userAuthorizedDownload) {
            _ in
        }
        XCTAssertEqual(initialPreparation, .ready)
        await fixture.provider.unload()

        let installedReadiness = await fixture.provider.readiness()
        let reloadReadiness = try await fixture.provider.prepare(.neverDownload) { _ in }
        let downloadCount = await fixture.downloader.callCount()
        let loadedDirectories = await fixture.loader.loadedDirectories()

        XCTAssertEqual(installedReadiness, .ready)
        XCTAssertEqual(reloadReadiness, .ready)
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(loadedDirectories.count, 3)
    }

    func testSynthesisPassesExactTextAndProfileAndEmitsFiniteMono24kPCM() async throws {
        let fixture = try ProviderFixture.make(runtimeBehavior: .chunks([[0, 0.25], [-0.5, 1, 0.1]]))
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }
        let request = Self.request(text: "Let's clarify `N` before choosing an architecture.")

        let events = try await Self.collect(try await fixture.provider.synthesize(request))

        XCTAssertEqual(events.count, 3)
        guard case .pcm(let first) = events[0],
              case .pcm(let second) = events[1],
              case .completed(let metrics) = events[2] else {
            return XCTFail("expected two PCM chunks and one completion")
        }
        XCTAssertEqual(first.samples, [0, 0.25])
        XCTAssertEqual(second.samples, [-0.5, 1, 0.1])
        XCTAssertEqual(first.sampleRate, 24_000)
        XCTAssertEqual(first.channelCount, 1)
        XCTAssertEqual(metrics.chunkCount, 2)
        XCTAssertEqual(metrics.generatedSampleCount, 5)
        XCTAssertNotNil(metrics.timeToFirstAudioMilliseconds)
        XCTAssertNotNil(metrics.totalGenerationMilliseconds)
        let observed = fixture.runtime.observedRequests()
        XCTAssertEqual(observed.map(\.text), [request.spokenText])
        XCTAssertEqual(observed.map(\.profile), [request.profile])
    }

    func testFullConsumeAllowsImmediateNextGeneration() async throws {
        let fixture = try ProviderFixture.make(runtimeBehavior: .chunks([[0.1]]))
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }

        _ = try await Self.collect(
            try await fixture.provider.synthesize(Self.request(text: "First question."))
        )
        let second = try await Self.collect(
            try await fixture.provider.synthesize(Self.request(text: "Second question."))
        )

        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(fixture.runtime.observedRequests().map(\.text), [
            "First question.", "Second question.",
        ])
    }

    func testSlowConsumerBackpressuresAndCompletesMoreThanTwentyFourChunks() async throws {
        let chunks = Array(repeating: [Float(0.1)], count: 32)
        let fixture = try ProviderFixture.make(runtimeBehavior: .chunks(chunks))
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }
        let stream = try await fixture.provider.synthesize(
            Self.request(text: "Backpressure valid long-form interviewer speech.")
        )
        var events = [InterviewerSpeechEvent]()

        for try await event in stream {
            events.append(event)
            if case .pcm = event {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let highWaterMark = await fixture.provider.outputBufferHighWaterMark()

        XCTAssertEqual(events.count, 33)
        XCTAssertEqual(events.compactMap(Self.pcmChunk).count, 32)
        XCTAssertTrue(highWaterMark > 0)
        XCTAssertTrue(highWaterMark <= QwenInterviewerSpeechProvider.outputBufferCapacity)
    }

    func testCancellationJoinsProducerSuspendedByBackpressure() async throws {
        let chunks = Array(repeating: [Float(0.1)], count: 32)
        let fixture = try ProviderFixture.make(runtimeBehavior: .chunks(chunks))
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }
        let stream = try await fixture.provider.synthesize(
            Self.request(text: "Cancel while bounded output is full.")
        )
        var iterator = stream.makeAsyncIterator()
        guard case .pcm = try await iterator.next() else {
            return XCTFail("expected the first PCM chunk")
        }
        try await Task.sleep(for: .milliseconds(20))

        await fixture.provider.cancelSynthesis()

        do {
            while try await iterator.next() != nil {}
            XCTFail("joined producer cancellation must terminate the stream")
        } catch let error as QwenInterviewerSpeechError {
            XCTAssertEqual(error, .cancelled)
        }
        let highWaterMark = await fixture.provider.outputBufferHighWaterMark()
        XCTAssertTrue(highWaterMark <= QwenInterviewerSpeechProvider.outputBufferCapacity)

        let retry = try await Self.collect(
            try await fixture.provider.synthesize(
                Self.request(text: "Prepared model remains retryable after cancellation.")
            )
        )
        XCTAssertEqual(retry.count, 33)
    }

    func testCancelSynthesisJoinsDelayedUpstreamTeardownBeforeImmediateRetry() async throws {
        let fixture = try ProviderFixture.make(
            runtimeBehavior: .delayedCancellationTeardown(
                chunks: Array(repeating: [Float(0.1)], count: 32),
                delay: .milliseconds(75)
            )
        )
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }
        let firstStream = try await fixture.provider.synthesize(
            Self.request(text: "Join the first upstream producer.")
        )
        await fixture.runtime.waitUntilDelayedProducerStarts(1)
        await fixture.runtime.waitUntilDelayedProducerYieldsAllChunks(1)

        await fixture.provider.cancelSynthesis()

        XCTAssertEqual(fixture.runtime.activeDelayedProducerCount(), 0)
        XCTAssertEqual(fixture.runtime.delayedTeardownCompletionCount(), 1)
        let retryStream = try await fixture.provider.synthesize(
            Self.request(text: "Retry only after teardown completes.")
        )
        await fixture.runtime.waitUntilDelayedProducerStarts(2)
        XCTAssertFalse(fixture.runtime.hadDelayedProducerOverlap())

        await fixture.provider.cancelSynthesis()

        XCTAssertEqual(fixture.runtime.activeDelayedProducerCount(), 0)
        XCTAssertEqual(fixture.runtime.delayedTeardownCompletionCount(), 2)
        XCTAssertFalse(fixture.runtime.hadDelayedProducerOverlap())
        withExtendedLifetime((firstStream, retryStream)) {}
    }

    func testInvalidAudioJoinsDelayedUpstreamTeardownBeforeOwnershipRelease() async throws {
        let fixture = try ProviderFixture.make(
            runtimeBehavior: .delayedCancellationTeardown(
                chunks: [[.nan]],
                delay: .milliseconds(75)
            )
        )
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }

        for attempt in 1 ... 2 {
            do {
                _ = try await Self.collect(
                    try await fixture.provider.synthesize(
                        Self.request(text: "Reject invalid audio after joining its producer.")
                    )
                )
                XCTFail("non-finite audio must fail")
            } catch let error as QwenInterviewerSpeechError {
                XCTAssertEqual(error, .invalidAudio)
            }
            XCTAssertEqual(fixture.runtime.activeDelayedProducerCount(), 0)
            XCTAssertEqual(fixture.runtime.delayedTeardownCompletionCount(), attempt)
            XCTAssertFalse(fixture.runtime.hadDelayedProducerOverlap())
        }
    }

    func testOversizedPCMChunkFailsBeforeEnteringBoundedBuffer() async throws {
        let oversized = [Float](
            repeating: 0.1,
            count: QwenInterviewerSpeechProvider.maximumChunkSampleCount + 1
        )
        let fixture = try ProviderFixture.make(runtimeBehavior: .chunks([oversized]))
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }

        do {
            _ = try await Self.collect(
                try await fixture.provider.synthesize(
                    Self.request(text: "Reject an unexpectedly large provider chunk.")
                )
            )
            XCTFail("an oversized upstream chunk must not enter the output buffer")
        } catch let error as QwenInterviewerSpeechError {
            XCTAssertEqual(error, .invalidAudio)
        }
    }

    func testTotalGeneratedSamplesCannotExceedProviderBoundary() async throws {
        let fullChunk = [Float](
            repeating: 0.1,
            count: QwenInterviewerSpeechProvider.maximumChunkSampleCount
        )
        let fullChunkCount = QwenInterviewerSpeechProvider.maximumGeneratedSampleCount
            / QwenInterviewerSpeechProvider.maximumChunkSampleCount
        let chunks = Array(repeating: fullChunk, count: fullChunkCount) + [[0.1]]
        let fixture = try ProviderFixture.make(runtimeBehavior: .chunks(chunks))
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }

        do {
            _ = try await Self.collect(
                try await fixture.provider.synthesize(
                    Self.request(text: "Enforce the total generated sample boundary.")
                )
            )
            XCTFail("provider output must not exceed 2,400,000 samples")
        } catch let error as QwenInterviewerSpeechError {
            XCTAssertEqual(error, .invalidAudio)
        }
    }

    func testRejectsEmptyNonFiniteAndWrongProfileWithoutLeakingText() async throws {
        let fixture = try ProviderFixture.make(runtimeBehavior: .chunks([[.nan]]))
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }

        do {
            _ = try await fixture.provider.synthesize(Self.request(text: "   "))
            XCTFail("empty speech must fail")
        } catch let error as QwenInterviewerSpeechError {
            XCTAssertEqual(error, .invalidRequest)
        }

        let wrongProfile = try InterviewerSpeechProfile(
            profileID: "fixture-v2",
            language: "English",
            conditioning: "Aiden, measured.",
            maxTokens: 100,
            temperature: 0.8,
            topP: 1,
            topK: 0,
            minP: 0,
            repetitionPenalty: 1.05,
            repetitionContextSize: 20,
            streamingInterval: 0.32
        )
        do {
            _ = try await fixture.provider.synthesize(
                Self.request(text: "private fixture words", profile: wrongProfile)
            )
            XCTFail("unapproved profile must fail")
        } catch let error as QwenInterviewerSpeechError {
            XCTAssertEqual(error, .profileMismatch)
            XCTAssertFalse(String(describing: error).contains("private fixture words"))
        }

        do {
            _ = try await Self.collect(
                try await fixture.provider.synthesize(Self.request(text: "Finite output only."))
            )
            XCTFail("NaN PCM must fail")
        } catch let error as QwenInterviewerSpeechError {
            XCTAssertEqual(error, .invalidAudio)
        }
    }

    func testStreamCancellationPropagatesUpstreamAndUnloadRequiresPrepareAgain() async throws {
        let fixture = try ProviderFixture.make(runtimeBehavior: .waitForCancellation)
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }
        let stream = try await fixture.provider.synthesize(Self.request(text: "Long response."))
        let consumer = Task {
            for try await _ in stream {}
        }
        await fixture.runtime.waitUntilStarted()
        consumer.cancel()
        _ = try? await consumer.value
        await fixture.runtime.waitUntilCancelled()
        XCTAssertTrue(fixture.runtime.wasCancelled())

        await fixture.provider.unload()
        do {
            _ = try await fixture.provider.synthesize(Self.request(text: "After unload."))
            XCTFail("unload must release process-loaded model")
        } catch let error as QwenInterviewerSpeechError {
            XCTAssertEqual(error, .notPrepared)
        }
    }

    func testCancelSynthesisJoinsProducerWithoutUnloadingPreparedModel() async throws {
        let fixture = try ProviderFixture.make(runtimeBehavior: .waitForCancellation)
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }
        let firstStream = try await fixture.provider.synthesize(
            Self.request(text: "Cancel this generation.")
        )
        let firstConsumer = Task {
            for try await _ in firstStream {}
        }
        await fixture.runtime.waitUntilStarted()

        await fixture.provider.cancelSynthesis()
        _ = try? await firstConsumer.value

        let secondStream = try await fixture.provider.synthesize(
            Self.request(text: "Prepared model remains available.")
        )
        let secondConsumer = Task {
            for try await _ in secondStream {}
        }
        await fixture.provider.cancelSynthesis()
        _ = try? await secondConsumer.value
        XCTAssertEqual(fixture.runtime.observedRequests().map(\.text), [
            "Cancel this generation.",
            "Prepared model remains available.",
        ])
    }

    func testRemovePreparedModelUnloadsAndDeletesOnlyExactRevision() async throws {
        let fixture = try ProviderFixture.make()
        defer { fixture.remove() }
        _ = try await fixture.provider.prepare(.userAuthorizedDownload) { _ in }
        let sentinel = fixture.root.appendingPathComponent("SessionManifests/keep.json")
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: sentinel)

        let removalReadiness = try await fixture.provider.removePreparedModel()
        let finalReadiness = await fixture.provider.readiness()
        let sentinelData = try Data(contentsOf: sentinel)

        XCTAssertEqual(removalReadiness, .notInstalled)
        XCTAssertEqual(sentinelData, Data("keep".utf8))
        XCTAssertEqual(finalReadiness, .notInstalled)
    }

    private static func request(
        text: String,
        profile: InterviewerSpeechProfile = .maraV1
    ) -> InterviewerSpeechSynthesisRequest {
        InterviewerSpeechSynthesisRequest(
            sessionID: SessionID("fixture-session"),
            turnID: TurnID("fixture-turn"),
            utteranceID: InterviewerUtteranceID("fixture-utterance"),
            attemptID: SynthesisAttemptID("fixture-attempt"),
            spokenText: text,
            profile: profile
        )
    }

    private static func collect(
        _ stream: AsyncThrowingStream<InterviewerSpeechEvent, Error>
    ) async throws -> [InterviewerSpeechEvent] {
        var result = [InterviewerSpeechEvent]()
        for try await event in stream { result.append(event) }
        return result
    }

    private static func pcmChunk(
        _ event: InterviewerSpeechEvent
    ) -> InterviewerSpeechPCMChunk? {
        guard case .pcm(let chunk) = event else { return nil }
        return chunk
    }
}

private struct ProviderFixture {
    let root: URL
    let modelRoot: URL
    let manifest: QwenSnapshotManifest
    let downloader: ProviderSnapshotDownloader
    let loader: ProviderModelLoader
    let runtime: ProviderRuntime
    let provider: QwenInterviewerSpeechProvider

    static func make(
        runtimeBehavior: ProviderRuntime.Behavior = .chunks([[0.1, -0.1]])
    ) throws -> ProviderFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-provider-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modelRoot = root.appendingPathComponent("Models", isDirectory: true)
        let contents: [String: Data] = [
            "config.json": Data(#"{"sample_rate":24000}"#.utf8),
            "speech_tokenizer/model.safetensors": Data([1, 2, 3, 4]),
        ]
        let manifest = QwenSnapshotManifest(
            repositoryID: "fixture/provider-model",
            revision: "1234567890abcdef1234567890abcdef12345678",
            files: contents.keys.sorted().map { path in
                let data = contents[path]!
                return QwenSnapshotFile(
                    path: path,
                    byteCount: Int64(data.count),
                    sha256: QwenSHA256.string(data)
                )
            }
        )
        let runtime = ProviderRuntime(behavior: runtimeBehavior)
        let loader = ProviderModelLoader(runtime: runtime)
        let downloader = ProviderSnapshotDownloader(contents: contents)
        let store = QwenModelStore(
            modelRoot: modelRoot,
            manifest: manifest,
            downloader: downloader,
            freeSpaceReader: ProviderFreeSpaceReader(),
            minimumFreeBytes: 1
        )
        let provider = QwenInterviewerSpeechProvider(store: store, loader: loader)
        return ProviderFixture(
            root: root,
            modelRoot: modelRoot,
            manifest: manifest,
            downloader: downloader,
            loader: loader,
            runtime: runtime,
            provider: provider
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension QwenInterviewerSpeechProviderFixture {
    static var publicProvenance: InterviewerSpeechProvenance {
        InterviewerSpeechProvenance(
            providerID: Qwen3TTSProvenance.providerID,
            modelID: Qwen3TTSProvenance.modelID,
            modelRevision: Qwen3TTSProvenance.modelRevision,
            profile: .maraV1
        )
    }
}

private enum QwenInterviewerSpeechProviderFixture {}

private struct ProviderFreeSpaceReader: QwenFreeSpaceReading {
    func availableBytes(for location: URL) throws -> Int64 {
        _ = location
        return 1_000_000
    }
}

private actor ProviderSnapshotDownloader: QwenSnapshotDownloading {
    private let contents: [String: Data]
    private var calls = 0

    init(contents: [String: Data]) {
        self.contents = contents
    }

    func downloadSnapshot(
        manifest: QwenSnapshotManifest,
        destination: URL,
        cacheRoot: URL,
        progress: @escaping @Sendable (QwenModelStoreProgress) -> Void
    ) async throws {
        _ = cacheRoot
        calls += 1
        for (path, data) in contents {
            let url = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        progress(
            QwenModelStoreProgress(
                stage: .downloading,
                completedBytes: manifest.byteCount,
                totalBytes: manifest.byteCount
            )
        )
    }

    func callCount() -> Int { calls }
}

private actor ProviderModelLoader: QwenSpeechModelLoading {
    private let runtime: ProviderRuntime
    private var directories = [URL]()

    init(runtime: ProviderRuntime) {
        self.runtime = runtime
    }

    func loadModel(from directory: URL) async throws -> any QwenStreamingSpeechModel {
        directories.append(directory)
        let tokenizer = directory.appendingPathComponent(QwenModelStore.derivedTokenizerName)
        if !FileManager.default.fileExists(atPath: tokenizer.path) {
            try Data(#"{"model":{"type":"BPE"}}"#.utf8).write(to: tokenizer)
        }
        return runtime
    }

    func loadedDirectories() -> [URL] { directories }
}

private final class ProviderRuntime: QwenStreamingSpeechModel, @unchecked Sendable {
    enum Behavior: Sendable {
        case chunks([[Float]])
        case waitForCancellation
        case delayedCancellationTeardown(chunks: [[Float]], delay: Duration)
    }

    struct ObservedRequest: Equatable {
        let text: String
        let profile: InterviewerSpeechProfile
    }

    let sampleRate = 24_000
    private let lock = NSLock()
    private let behavior: Behavior
    private var requests = [ObservedRequest]()
    private var started = false
    private var cancelled = false
    private var activeDelayedProducers = 0
    private var delayedProducerOverlap = false
    private let delayedProducerStarts = ProviderCountSignal()
    private let delayedProducerYields = ProviderCountSignal()
    private let delayedTeardownCompletions = ProviderCountSignal()

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func startGeneration(
        text: String,
        profile: InterviewerSpeechProfile
    ) -> any QwenSpeechGeneration {
        lock.withLock { requests.append(ObservedRequest(text: text, profile: profile)) }
        switch behavior {
        case .chunks(let chunks):
            let stream = AsyncThrowingStream<[Float], Error> { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
            return ProviderTestGeneration(stream: stream, producerTask: nil)
        case .waitForCancellation:
            let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
            let task = Task.detached { [weak self] in
                self?.lock.withLock { self?.started = true }
                do {
                    while true { try await Task.sleep(for: .seconds(10)) }
                } catch {
                    self?.lock.withLock { self?.cancelled = true }
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
            return ProviderTestGeneration(stream: stream, producerTask: task)
        case .delayedCancellationTeardown(let chunks, let delay):
            let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                self.beginDelayedProducer()
                do {
                    for chunk in chunks {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    self.delayedProducerYields.increment()
                    while true {
                        try await Task.sleep(for: .seconds(10))
                    }
                } catch {
                    let teardown = Task.detached {
                        try? await Task.sleep(for: delay)
                    }
                    await teardown.value
                    self.finishDelayedProducer()
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
            return ProviderTestGeneration(stream: stream, producerTask: task)
        }
    }

    func observedRequests() -> [ObservedRequest] {
        lock.withLock { requests }
    }

    func wasCancelled() -> Bool {
        lock.withLock { cancelled }
    }

    func waitUntilStarted() async {
        for _ in 0 ..< 100 where !lock.withLock({ started }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilCancelled() async {
        for _ in 0 ..< 100 where !lock.withLock({ cancelled }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilDelayedProducerStarts(_ count: Int) async {
        await delayedProducerStarts.wait(until: count)
    }

    func waitUntilDelayedProducerYieldsAllChunks(_ count: Int) async {
        await delayedProducerYields.wait(until: count)
    }

    func activeDelayedProducerCount() -> Int {
        lock.withLock { activeDelayedProducers }
    }

    func delayedTeardownCompletionCount() -> Int {
        delayedTeardownCompletions.value
    }

    func hadDelayedProducerOverlap() -> Bool {
        lock.withLock { delayedProducerOverlap }
    }

    private func beginDelayedProducer() {
        lock.withLock {
            activeDelayedProducers += 1
            if activeDelayedProducers > 1 {
                delayedProducerOverlap = true
            }
        }
        delayedProducerStarts.increment()
    }

    private func finishDelayedProducer() {
        lock.withLock { activeDelayedProducers -= 1 }
        delayedTeardownCompletions.increment()
    }
}

/// Test double for the pinned upstream Qwen handle. `cancelAndWait` joins the
/// exact producer Task, including deliberately non-cancellable teardown.
private final class ProviderTestGeneration: QwenSpeechGeneration, @unchecked Sendable {
    private var iterator: AsyncThrowingStream<[Float], Error>.Iterator
    private let producerTask: Task<Void, Never>?

    init(
        stream: AsyncThrowingStream<[Float], Error>,
        producerTask: Task<Void, Never>?
    ) {
        iterator = stream.makeAsyncIterator()
        self.producerTask = producerTask
    }

    func nextSamples() async throws -> [Float]? {
        try await iterator.next()
    }

    func cancelAndWait() async {
        guard let producerTask else { return }
        producerTask.cancel()
        await producerTask.value
    }
}

private final class ProviderCountSignal: @unchecked Sendable {
    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var count = 0
    private var waiters = [Waiter]()

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        let ready = lock.withLock { () -> [Waiter] in
            count += 1
            let ready = waiters.filter { $0.target <= count }
            waiters.removeAll { $0.target <= count }
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(until target: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard count < target else { return true }
                waiters.append(Waiter(target: target, continuation: continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

}

private final class ProviderProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [InterviewerSpeechPreparationProgress]()

    var values: [InterviewerSpeechPreparationProgress] {
        lock.withLock { stored }
    }

    func append(_ value: InterviewerSpeechPreparationProgress) {
        lock.withLock { stored.append(value) }
    }
}
