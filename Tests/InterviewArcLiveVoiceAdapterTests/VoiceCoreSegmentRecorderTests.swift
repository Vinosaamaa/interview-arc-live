import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore
import XCTest
@testable import InterviewArcLiveVoiceAdapter

@MainActor
final class VoiceCoreSegmentRecorderTests: XCTestCase {
    func testAdoptsAuthoritativeRecoveredURLAndPreservesPartialMetadata() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.remove() }
        let driver = RecordingDriverSpy(finalFileName: "answer-recovered-safe.m4a")
        var dates = [
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 105),
        ]
        let recorder = VoiceCoreSegmentRecorder(
            driver: driver,
            applicationSupportRoot: fixture.root,
            now: { dates.removeFirst() },
            inspect: { capture in
                XCTAssertEqual(
                    capture.url.lastPathComponent,
                    "answer-recovered-safe.m4a"
                )
                return RecordingIntegrityEvidence(
                    wallDurationSeconds: 5,
                    decodedDurationSeconds: 3,
                    fileSizeBytes: 2_048,
                    decodedFrameCount: 144_000,
                    writeErrorDescription: nil
                )
            }
        )

        let request = try fixture.captureRequest(fileName: "answer.m4a")
        try await recorder.beginCapture(request)
        let captured = try await recorder.finishCapture()

        XCTAssertEqual(captured.audioIdentity.fileName, "answer-recovered-safe.m4a")
        XCTAssertEqual(captured.startedAtMilliseconds, 100_000)
        XCTAssertEqual(captured.endedAtMilliseconds, 105_000)
        XCTAssertEqual(captured.durationMilliseconds, 5_000)
        XCTAssertEqual(captured.decodedDurationMilliseconds, 3_000)
        XCTAssertEqual(captured.byteCount, 2_048)
        XCTAssertTrue(captured.isPlayable)
        XCTAssertTrue(captured.isPartial)
        XCTAssertEqual(
            captured.integrityReasons,
            [SegmentIntegrityReason("durationMismatch")]
        )
        XCTAssertNotEqual(driver.requestedURL, driver.finalizedURL)

        let playbackURL = try await recorder.playbackURL(
            sessionID: request.sessionID,
            audioIdentity: captured.audioIdentity
        )
        XCTAssertEqual(playbackURL, driver.finalizedURL?.standardizedFileURL)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: playbackURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
        try fixture.assertPrivateDirectoryPermissions()
    }

    func testUnexpectedTerminationHandlerIsOneShotPerCapture() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.remove() }
        let driver = RecordingDriverSpy(finalFileName: "answer.m4a")
        let recorder = VoiceCoreSegmentRecorder(
            driver: driver,
            applicationSupportRoot: fixture.root,
            inspect: { _ in Self.completeEvidence }
        )
        var eventCount = 0
        recorder.setUnexpectedTerminationHandler { eventCount += 1 }

        try await recorder.beginCapture(
            fixture.captureRequest(fileName: "answer.m4a")
        )
        driver.emitUnexpectedTermination()
        driver.emitUnexpectedTermination()

        XCTAssertEqual(eventCount, 1)
        _ = try await recorder.finishCapture()
        driver.emitUnexpectedTermination()
        XCTAssertEqual(eventCount, 1)
    }

    func testSuccessfulStopClearsCaptureEvenWhenAuthoritativePathIsRejected() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.remove() }
        let outsideURL = fixture.root
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let driver = RecordingDriverSpy(finalizedURL: outsideURL)
        let recorder = VoiceCoreSegmentRecorder(
            driver: driver,
            applicationSupportRoot: fixture.root,
            inspect: { _ in Self.completeEvidence }
        )

        try await recorder.beginCapture(
            fixture.captureRequest(fileName: "first.m4a")
        )
        do {
            _ = try await recorder.finishCapture()
            XCTFail("Expected an out-of-root capture rejection")
        } catch let error as VoiceCoreSegmentRecorderError {
            XCTAssertEqual(error, .authoritativeCaptureOutsideSessionRoot)
        }

        driver.finalFileName = "second.m4a"
        driver.finalizedURLOverride = nil
        try await recorder.beginCapture(
            fixture.captureRequest(fileName: "second.m4a")
        )
        _ = try await recorder.finishCapture()
        XCTAssertEqual(driver.stopCount, 2)
    }

    func testStopFailureKeepsCaptureAvailableForExplicitFinalizationRetry() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.remove() }
        let driver = RecordingDriverSpy(finalFileName: "answer.m4a")
        driver.stopFailuresRemaining = 1
        let recorder = VoiceCoreSegmentRecorder(
            driver: driver,
            applicationSupportRoot: fixture.root,
            inspect: { _ in Self.completeEvidence }
        )

        try await recorder.beginCapture(
            fixture.captureRequest(fileName: "answer.m4a")
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await recorder.finishCapture()
        }
        _ = try await recorder.finishCapture()
        XCTAssertEqual(driver.stopCount, 2)
    }

    func testRecoveryPrefersNewestPlayableRecoveredFileWithoutDeletingSources() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.remove() }
        let paths = LiveVoicePaths(applicationSupportRoot: fixture.root)
        let request = try fixture.captureRequest(fileName: "answer.m4a")
        let reservedURL = try paths.audioURL(
            sessionID: request.sessionID,
            identity: request.reservedAudioIdentity,
            createParentDirectory: true
        )
        let recoveredIdentity = try SegmentAudioIdentity(
            validating: "answer-recovered-public.m4a"
        )
        let recoveredURL = try paths.audioURL(
            sessionID: request.sessionID,
            identity: recoveredIdentity,
            createParentDirectory: false
        )
        try Data(repeating: 1, count: 2_048).write(to: reservedURL)
        try Data(repeating: 2, count: 4_096).write(to: recoveredURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: reservedURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 210)],
            ofItemAtPath: recoveredURL.path
        )
        let recorder = VoiceCoreSegmentRecorder(
            driver: RecordingDriverSpy(finalFileName: "unused.m4a"),
            applicationSupportRoot: fixture.root,
            inspect: { capture in
                RecordingIntegrityEvidence(
                    wallDurationSeconds: 0,
                    decodedDurationSeconds:
                        capture.url == recoveredURL ? 4 : 3,
                    fileSizeBytes:
                        capture.url == recoveredURL ? 4_096 : 2_048,
                    decodedFrameCount: 192_000,
                    writeErrorDescription: nil,
                    peakPowerDecibels:
                        capture.url == recoveredURL ? -70 : -12
                )
            }
        )

        let recovered = try await recorder.recoverCapture(request)

        XCTAssertEqual(recovered?.audioIdentity, recoveredIdentity)
        XCTAssertEqual(recovered?.startedAtMilliseconds, 206_000)
        XCTAssertEqual(recovered?.endedAtMilliseconds, 210_000)
        XCTAssertEqual(recovered?.durationMilliseconds, 4_000)
        XCTAssertEqual(recovered?.byteCount, 4_096)
        XCTAssertEqual(recovered?.isPlayable, true)
        XCTAssertEqual(recovered?.isPartial, true)
        XCTAssertTrue(
            recovered?.integrityReasons.contains(.insufficientSignal) == true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))
    }

    func testRecoveryReturnsNilWhenNoValidatedPlayableSourceExists() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.remove() }
        let paths = LiveVoicePaths(applicationSupportRoot: fixture.root)
        let request = try fixture.captureRequest(fileName: "answer.m4a")
        let reservedURL = try paths.audioURL(
            sessionID: request.sessionID,
            identity: request.reservedAudioIdentity,
            createParentDirectory: true
        )
        try Data(repeating: 1, count: 64).write(to: reservedURL)
        let recorder = VoiceCoreSegmentRecorder(
            driver: RecordingDriverSpy(finalFileName: "unused.m4a"),
            applicationSupportRoot: fixture.root,
            inspect: { _ in
                RecordingIntegrityEvidence(
                    wallDurationSeconds: 0,
                    decodedDurationSeconds: 0,
                    fileSizeBytes: 64,
                    decodedFrameCount: 0,
                    writeErrorDescription: nil
                )
            }
        )

        let recovered = try await recorder.recoverCapture(request)
        XCTAssertNil(recovered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedURL.path))
    }

    private static let completeEvidence = RecordingIntegrityEvidence(
        wallDurationSeconds: 2,
        decodedDurationSeconds: 2,
        fileSizeBytes: 2_048,
        decodedFrameCount: 96_000,
        writeErrorDescription: nil,
        peakPowerDecibels: -12
    )
}

@MainActor
private final class RecordingDriverSpy: VoiceCoreRecordingDriving {
    var onUnexpectedTermination: (@MainActor () -> Void)?
    var finalFileName: String
    var finalizedURLOverride: URL?
    var stopFailuresRemaining = 0
    private(set) var requestedURL: URL?
    private(set) var finalizedURL: URL?
    private(set) var stopCount = 0

    init(finalFileName: String) {
        self.finalFileName = finalFileName
    }

    init(finalizedURL: URL) {
        finalFileName = finalizedURL.lastPathComponent
        finalizedURLOverride = finalizedURL
    }

    func start(
        at destinationURL: URL,
        captureBackendDidStart: @escaping @MainActor () -> Void
    ) async throws {
        requestedURL = destinationURL
        captureBackendDidStart()
    }

    func stop() throws -> RecordedCapture {
        stopCount += 1
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw VoiceBridgeError.recordingUnavailable
        }
        guard let requestedURL else {
            throw VoiceBridgeError.recordingUnavailable
        }
        let url = finalizedURLOverride
            ?? requestedURL.deletingLastPathComponent().appendingPathComponent(
                finalFileName
            )
        try Data(repeating: 1, count: 2_048).write(to: url, options: .atomic)
        finalizedURL = url
        return RecordedCapture(
            url: url,
            duration: 5,
            writtenFrameCount: 144_000,
            writeErrorDescription: nil,
            peakPowerDecibels: -12
        )
    }

    func emitUnexpectedTermination() {
        onUnexpectedTermination?()
    }
}

private struct RecordingFixture {
    let root: URL
    let sessionID = SessionID("public-test-session")

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-recorder-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func captureRequest(fileName: String) throws -> SegmentCaptureRequest {
        SegmentCaptureRequest(
            sessionID: sessionID,
            segmentID: SegmentID("segment-test"),
            reservedAudioIdentity: try SegmentAudioIdentity(
                validating: fileName
            )
        )
    }

    func assertPrivateDirectoryPermissions() throws {
        let paths = LiveVoicePaths(applicationSupportRoot: root)
        let audioDirectory = try paths.sessionAudioDirectory(
            sessionID: sessionID,
            create: false
        )
        for directory in [
            root,
            root.appendingPathComponent("Audio", isDirectory: true),
            audioDirectory,
        ] {
            let permissions = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )[.posixPermissions] as? NSNumber
            XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o700)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
