import AVFoundation
import CryptoKit
import Foundation
import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLiveSpeechOutputAdapter

@MainActor
final class PrivateInterviewerWaveStoreTests: XCTestCase {
    func testPublicSmokeInitializerIsConfinedToDedicatedTemporaryChild() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
        let allowed = temporaryRoot.appendingPathComponent(
            "interview-arc-live-speech-smoke-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: allowed) }

        XCTAssertNoThrow(
            try LiveInterviewerSpeechAudioStore(
                validatingTemporarySmokeRoot: allowed
            )
        )
        let wrapperOwned = temporaryRoot.appendingPathComponent(
            "interview-arc-live-speech-smoke.\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: wrapperOwned) }
        XCTAssertNoThrow(
            try LiveInterviewerSpeechAudioStore(
                validatingTemporarySmokeRoot: wrapperOwned
            )
        )
        XCTAssertThrowsError(
            try LiveInterviewerSpeechAudioStore(
                validatingTemporarySmokeRoot: temporaryRoot.appendingPathComponent(
                    "not-a-live-speech-smoke",
                    isDirectory: true
                )
            )
        )
        XCTAssertThrowsError(
            try LiveInterviewerSpeechAudioStore(
                validatingTemporarySmokeRoot: allowed.appendingPathComponent(
                    "nested",
                    isDirectory: true
                )
            )
        )
    }

    func testFinalizesDeterministicPrivateFloat32WaveAndRemovesPartial() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let samples: [Float] = [-0.75, -0.25, 0, 0.25, 0.75]

        let firstResult = try await write(
            samples: samples,
            fixture: first,
            session: "public-session",
            attempt: "public-attempt"
        )
        let secondResult = try await write(
            samples: samples,
            fixture: second,
            session: "public-session",
            attempt: "public-attempt"
        )

        XCTAssertEqual(firstResult.descriptor, secondResult.descriptor)
        XCTAssertEqual(firstResult.data, secondResult.data)
        XCTAssertEqual(firstResult.data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(firstResult.data[8..<12], Data("WAVE".utf8))
        XCTAssertEqual(firstResult.data[20], 3)
        XCTAssertEqual(firstResult.data[22], 1)
        XCTAssertEqual(firstResult.descriptor.sampleRate, 24_000)
        XCTAssertEqual(firstResult.descriptor.channelCount, 1)
        XCTAssertEqual(firstResult.descriptor.frameCount, samples.count)
        XCTAssertEqual(
            firstResult.descriptor.byteCount,
            PrivateInterviewerWaveStore.headerByteCount
                + samples.count * MemoryLayout<Float>.size
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstResult.partialURL.path)
        )
        try assertPrivatePermissions(
            root: first.root,
            finalURL: firstResult.finalURL
        )
    }

    func testPostMoveFailureRemovesFinalArtifactAndAllowsSameAttemptRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let postMoveGate = FailFirstPostMoveValidation()
        let store = PrivateInterviewerWaveStore(
            applicationSupportRoot: fixture.root,
            postMoveValidation: { finalURL in
                try postMoveGate.validate(finalURL)
            }
        )
        let token = try await beginWrite(
            in: store,
            session: "post-move-session",
            attempt: "post-move-attempt"
        )
        try await store.append(
            [0.125, 0.25],
            sampleRate: 24_000,
            channelCount: 1,
            to: token
        )

        do {
            _ = try await store.finalize(token)
            XCTFail("Expected the injected post-move gate to fail")
        } catch let failure as InjectedWaveStoreFailure {
            XCTAssertEqual(failure, .afterFinalMove)
        }

        let remainingNames = FileManager.default
            .enumerator(at: fixture.root, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertFalse(remainingNames.contains(token.finalFileName))
        XCTAssertFalse(remainingNames.contains(token.partialFileName))

        let retry = try await beginWrite(
            in: store,
            session: "post-move-session",
            attempt: "post-move-attempt"
        )
        try await store.append(
            [0.375, 0.5],
            sampleRate: 24_000,
            channelCount: 1,
            to: retry
        )
        let retriedDescriptor = try await store.finalize(retry)
        let retriedURL = try await store.playbackURL(
            sessionIdentity: "post-move-session",
            fileName: retriedDescriptor.fileName
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retriedURL.path))
    }

    func testRejectsWrongFormatNonFiniteEmptyAndBoundedOverflow() async throws {
        for rejected in [
            RejectedAppend.wrongRate,
            .wrongChannels,
            .empty,
            .notFinite,
            .tooLong,
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let store = PrivateInterviewerWaveStore(
                applicationSupportRoot: fixture.root,
                maximumFrameCount: 2
            )
            let token = try await beginWrite(
                in: store,
                session: "session-\(rejected)",
                attempt: "attempt-\(rejected)"
            )

            do {
                switch rejected {
                case .wrongRate:
                    try await store.append(
                        [0],
                        sampleRate: 16_000,
                        channelCount: 1,
                        to: token
                    )
                case .wrongChannels:
                    try await store.append(
                        [0],
                        sampleRate: 24_000,
                        channelCount: 2,
                        to: token
                    )
                case .empty:
                    try await store.append(
                        [],
                        sampleRate: 24_000,
                        channelCount: 1,
                        to: token
                    )
                case .notFinite:
                    try await store.append(
                        [.nan],
                        sampleRate: 24_000,
                        channelCount: 1,
                        to: token
                    )
                case .tooLong:
                    try await store.append(
                        [0, 0, 0],
                        sampleRate: 24_000,
                        channelCount: 1,
                        to: token
                    )
                }
                XCTFail("Expected \(rejected) to be rejected")
            } catch let error as PrivateInterviewerWaveStoreError {
                XCTAssertEqual(error, rejected.expectedError)
            }

            await store.discard(token)
        }
    }

    func testTamperedFinalWaveDoesNotValidateForPlaybackOrRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = PrivateInterviewerWaveStore(
            applicationSupportRoot: fixture.root
        )
        let token = try await beginWrite(
            in: store,
            session: "public-session",
            attempt: "public-attempt"
        )
        try await store.append(
            [0.1, 0.2],
            sampleRate: 24_000,
            channelCount: 1,
            to: token
        )
        let descriptor = try await store.finalize(token)
        let finalURL = try await store.playbackURL(
            sessionIdentity: "public-session",
            fileName: descriptor.fileName
        )
        var data = try Data(contentsOf: finalURL)
        data[20] = 1
        try data.write(to: finalURL, options: .atomic)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.inspectFinal(
                sessionIdentity: "public-session",
                fileName: descriptor.fileName
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await store.playbackURL(
                sessionIdentity: "public-session",
                fileName: descriptor.fileName
            )
        }
    }

    func testDiscardRemovesOnlyAttemptPartialAndLeavesCompletedAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = PrivateInterviewerWaveStore(
            applicationSupportRoot: fixture.root
        )
        let completed = try await beginWrite(
            in: store,
            session: "public-session",
            attempt: "completed-attempt"
        )
        try await store.append(
            [0.1],
            sampleRate: 24_000,
            channelCount: 1,
            to: completed
        )
        let descriptor = try await store.finalize(completed)
        let interrupted = try await beginWrite(
            in: store,
            session: "public-session",
            attempt: "interrupted-attempt"
        )
        try await store.append(
            [0.2],
            sampleRate: 24_000,
            channelCount: 1,
            to: interrupted
        )

        await store.discard(interrupted)

        let completedURL = try await store.playbackURL(
            sessionIdentity: "public-session",
            fileName: descriptor.fileName
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: completedURL.deletingLastPathComponent()
                    .appendingPathComponent(interrupted.partialFileName).path
            )
        )
    }

    func testSelectedArtifactHashMismatchPreventsPlaybackBeforeOutputStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LiveInterviewerSpeechAudioStore(
            applicationSupportRoot: fixture.root
        )
        let request = try makeCoreWriteRequest(
            session: "artifact-session",
            attempt: "artifact-attempt"
        )
        try await store.beginWrite(request)
        try await store.append(
            InterviewerSpeechPCMChunk(
                samples: [0.125, 0.25],
                sampleRate: 24_000,
                channelCount: 1
            ),
            attemptID: request.attemptID
        )
        let artifact = try await store.finalizeWrite(
            attemptID: request.attemptID
        )
        let finalURL = try await store.playbackURL(
            sessionID: request.sessionID,
            artifact: artifact
        )
        var tampered = try Data(contentsOf: finalURL)
        tampered[PrivateInterviewerWaveStore.headerByteCount] ^= 0x01
        try tampered.write(to: finalURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: finalURL.path
        )
        let output = AudioOutputSpy()
        let player = AVAudioEngineInterviewerSpeechPlayer(
            audioStore: store,
            output: output
        )

        let isValid = await store.validateAudio(
            sessionID: request.sessionID,
            artifact: artifact
        )
        XCTAssertFalse(isValid)
        await XCTAssertThrowsErrorAsync {
            try await player.play(
                InterviewerSpeechPlaybackRequest(
                    sessionID: request.sessionID,
                    artifact: artifact
                )
            )
        }
        XCTAssertEqual(output.configureCount, 0)
        XCTAssertEqual(output.scheduledFileCount, 0)
        XCTAssertFalse(output.isOutputRouteHeld)
    }

    func testCompletedSavedPlaybackReleasesAudioOutputRoute() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LiveInterviewerSpeechAudioStore(
            applicationSupportRoot: fixture.root
        )
        let request = try makeCoreWriteRequest(
            session: "playback-session",
            attempt: "playback-attempt"
        )
        try await store.beginWrite(request)
        try await store.append(
            InterviewerSpeechPCMChunk(
                samples: [0.125, 0.25],
                sampleRate: 24_000,
                channelCount: 1
            ),
            attemptID: request.attemptID
        )
        let artifact = try await store.finalizeWrite(
            attemptID: request.attemptID
        )
        let output = AudioOutputSpy()
        let player = AVAudioEngineInterviewerSpeechPlayer(
            audioStore: store,
            output: output
        )

        try await player.play(
            InterviewerSpeechPlaybackRequest(
                sessionID: request.sessionID,
                artifact: artifact
            )
        )

        XCTAssertEqual(output.configureCount, 1)
        XCTAssertEqual(output.scheduledFileCount, 1)
        XCTAssertEqual(output.playCount, 1)
        XCTAssertFalse(output.isOutputRouteHeld)
        XCTAssertGreaterThanOrEqual(output.releaseCount, 2)
    }

    func testStreamingQueueBackpressuresUntilAPlayedBufferReleasesCapacity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LiveInterviewerSpeechAudioStore(
            applicationSupportRoot: fixture.root
        )
        let output = AudioOutputSpy(
            completesScheduledBuffersImmediately: false
        )
        let player = AVAudioEngineInterviewerSpeechPlayer(
            audioStore: store,
            output: output
        )
        let chunk = InterviewerSpeechPCMChunk(
            samples: [0.125],
            sampleRate: 24_000,
            channelCount: 1
        )
        try await player.beginStreaming(sampleRate: 24_000, channelCount: 1)
        for _ in 0..<AVAudioEngineInterviewerSpeechPlayer.maximumPendingBufferCount {
            try await player.enqueue(chunk)
        }

        let blockedEnqueue = Task { @MainActor in
            try await player.enqueue(chunk)
        }
        await Task.yield()
        XCTAssertEqual(
            output.scheduledBufferCount,
            AVAudioEngineInterviewerSpeechPlayer.maximumPendingBufferCount
        )

        output.completeNextScheduledBuffer()
        try await blockedEnqueue.value
        XCTAssertEqual(
            output.scheduledBufferCount,
            AVAudioEngineInterviewerSpeechPlayer.maximumPendingBufferCount + 1
        )
        await player.stop()
    }

    func testStopCancelsAnEnqueueWaitingForBufferCapacity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LiveInterviewerSpeechAudioStore(
            applicationSupportRoot: fixture.root
        )
        let output = AudioOutputSpy(
            completesScheduledBuffersImmediately: false
        )
        let player = AVAudioEngineInterviewerSpeechPlayer(
            audioStore: store,
            output: output
        )
        let chunk = InterviewerSpeechPCMChunk(
            samples: [0.125],
            sampleRate: 24_000,
            channelCount: 1
        )
        try await player.beginStreaming(sampleRate: 24_000, channelCount: 1)
        for _ in 0..<AVAudioEngineInterviewerSpeechPlayer.maximumPendingBufferCount {
            try await player.enqueue(chunk)
        }
        let blockedEnqueue = Task { @MainActor in
            try await player.enqueue(chunk)
        }
        await Task.yield()

        await player.stop()

        do {
            try await blockedEnqueue.value
            XCTFail("Expected Stop to cancel the capacity waiter")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func write(
        samples: [Float],
        fixture: Fixture,
        session: String,
        attempt: String
    ) async throws -> WriteResult {
        let store = PrivateInterviewerWaveStore(
            applicationSupportRoot: fixture.root
        )
        let token = try await beginWrite(
            in: store,
            session: session,
            attempt: attempt
        )
        try await store.append(
            samples,
            sampleRate: 24_000,
            channelCount: 1,
            to: token
        )
        let descriptor = try await store.finalize(token)
        let finalURL = try await store.playbackURL(
            sessionIdentity: session,
            fileName: descriptor.fileName
        )
        return WriteResult(
            descriptor: descriptor,
            data: try Data(contentsOf: finalURL),
            finalURL: finalURL,
            partialURL: finalURL.deletingLastPathComponent()
                .appendingPathComponent(token.partialFileName)
        )
    }

    private func beginWrite(
        in store: PrivateInterviewerWaveStore,
        session: String,
        attempt: String
    ) async throws -> PrivateInterviewerWaveWriteToken {
        let digest = SHA256.hash(data: Data(attempt.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try await store.begin(
            sessionIdentity: session,
            attemptIdentity: attempt,
            partialFileName: "speech-\(digest).partial.wav",
            finalFileName: "speech-\(digest).wav"
        )
    }

    private func makeCoreWriteRequest(
        session: String,
        attempt: String
    ) throws -> InterviewerSpeechAudioWriteRequest {
        let digest = SHA256.hash(data: Data(attempt.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return InterviewerSpeechAudioWriteRequest(
            sessionID: SessionID(session),
            utteranceID: InterviewerUtteranceID("utterance-\(attempt)"),
            attemptID: SynthesisAttemptID(attempt),
            partialAudioIdentity: try InterviewerAudioIdentity(
                validating: "speech-\(digest).partial.wav"
            ),
            finalAudioIdentity: try InterviewerAudioIdentity(
                validating: "speech-\(digest).wav"
            )
        )
    }

    private func assertPrivatePermissions(root: URL, finalURL: URL) throws {
        let directories = [
            root,
            root.appendingPathComponent("InterviewerSpeech"),
            finalURL.deletingLastPathComponent(),
        ]
        for directory in directories {
            let permissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(
                    atPath: directory.path
                )[.posixPermissions] as? NSNumber
            )
            XCTAssertEqual(permissions.intValue & 0o777, 0o700)
        }
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: finalURL.path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
    }
}

@MainActor
private final class AudioOutputSpy: InterviewerAudioOutputDriving {
    private let completesScheduledBuffersImmediately: Bool
    private var scheduledBufferCompletions: [@Sendable () -> Void] = []
    private(set) var configureCount = 0
    private(set) var scheduledFileCount = 0
    private(set) var scheduledBufferCount = 0
    private(set) var playCount = 0
    private(set) var releaseCount = 0
    private(set) var isOutputRouteHeld = false

    init(completesScheduledBuffersImmediately: Bool = true) {
        self.completesScheduledBuffersImmediately =
            completesScheduledBuffersImmediately
    }

    var isPlaying: Bool { isOutputRouteHeld && playCount > 0 }

    func configure(format: AVAudioFormat) throws {
        configureCount += 1
        isOutputRouteHeld = true
    }

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void
    ) {
        scheduledBufferCount += 1
        if completesScheduledBuffersImmediately {
            completion()
        } else {
            scheduledBufferCompletions.append(completion)
        }
    }

    func schedule(
        file: AVAudioFile,
        completion: @escaping @Sendable () -> Void
    ) {
        scheduledFileCount += 1
        completion()
    }

    func play() {
        playCount += 1
    }

    func releaseOutput() {
        releaseCount += 1
        isOutputRouteHeld = false
    }

    func completeNextScheduledBuffer() {
        guard !scheduledBufferCompletions.isEmpty else { return }
        scheduledBufferCompletions.removeFirst()()
    }
}

private enum RejectedAppend: CustomStringConvertible {
    case wrongRate
    case wrongChannels
    case empty
    case notFinite
    case tooLong

    var expectedError: PrivateInterviewerWaveStoreError {
        switch self {
        case .wrongRate, .wrongChannels:
            return .invalidFormat
        case .empty:
            return .emptyChunk
        case .notFinite:
            return .nonFiniteSample
        case .tooLong:
            return .durationLimitExceeded
        }
    }

    var description: String {
        switch self {
        case .wrongRate: return "wrong-rate"
        case .wrongChannels: return "wrong-channels"
        case .empty: return "empty"
        case .notFinite: return "not-finite"
        case .tooLong: return "too-long"
        }
    }
}

private enum InjectedWaveStoreFailure: Error, Equatable {
    case afterFinalMove
    case finalMissingBeforeGate
}

private final class FailFirstPostMoveValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func validate(_ finalURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard shouldFail else { return }
        shouldFail = false
        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            throw InjectedWaveStoreFailure.finalMissingBeforeGate
        }
        throw InjectedWaveStoreFailure.afterFinalMove
    }
}

private struct WriteResult {
    let descriptor: PrivateInterviewerWaveDescriptor
    let data: Data
    let finalURL: URL
    let partialURL: URL
}

private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-speech-store-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
