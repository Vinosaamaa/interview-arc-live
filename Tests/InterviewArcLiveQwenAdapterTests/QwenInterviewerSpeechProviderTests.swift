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

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func generateSamples(
        text: String,
        profile: InterviewerSpeechProfile
    ) -> AsyncThrowingStream<[Float], Error> {
        lock.withLock { requests.append(ObservedRequest(text: text, profile: profile)) }
        switch behavior {
        case .chunks(let chunks):
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        case .waitForCancellation:
            return AsyncThrowingStream { continuation in
                let task = Task { [weak self] in
                    self?.lock.withLock { self?.started = true }
                    do {
                        while true { try await Task.sleep(for: .seconds(10)) }
                    } catch {
                        self?.lock.withLock { self?.cancelled = true }
                        continuation.finish(throwing: CancellationError())
                    }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
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
