import AVFoundation
import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore
import XCTest
@testable import InterviewArcLiveVoiceAdapter

@MainActor
final class VoiceCoreAcousticCaptureTests: XCTestCase {
    func testDetectedOnsetSurvivesDelayedCaptureAndUsesTheSameInputStream() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-acoustic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = VoiceCoreAcousticSegmenter(requestPermission: { true }, startInput: {})
        let recorder = VoiceCoreSegmentRecorder(driver: input, applicationSupportRoot: root,
            inspect: RecordingFileInspector.inspect)
        var starts = 0
        input.setEventHandler { if $0 == .speechStarted { starts += 1 } }
        try await input.arm(.candidateListening)
        let samples = (0..<1_024).map { Float(sin(Double($0) * 0.0627) * 0.2) }
        // Speech is detected after eight frames. Setup is deliberately delayed
        // for four more frames; all twelve must enter the saved recording.
        for _ in 0..<12 { input.ingest(rms: 0.14, samples: samples) }
        XCTAssertEqual(starts, 1)
        try await recorder.beginCapture(.init(sessionID: SessionID("onset-test"),
            segmentID: SegmentID("onset-segment"),
            reservedAudioIdentity: try SegmentAudioIdentity(validating: "onset.m4a")))
        for _ in 0..<9 { input.ingest(rms: 0.14, samples: samples) }
        let capture = try await recorder.finishCapture()
        XCTAssertEqual(capture.durationMilliseconds, Int64((Double(21 * 1_024) / 44_100 * 1_000).rounded()))
        XCTAssertTrue(capture.isPlayable)
        XCTAssertTrue(capture.integrityReasons.isEmpty)
        let url = try await recorder.playbackURL(sessionID: SessionID("onset-test"),
            audioIdentity: capture.audioIdentity)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThanOrEqual(file.length, Int64(21 * 1_024))
        XCTAssertLessThan(file.length, Int64(23 * 1_024))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
        await input.disarm()
    }

    func testPermissionDenialIsReportedBeforeInputStarts() async {
        var inputStarts = 0
        let input = VoiceCoreAcousticSegmenter(requestPermission: { false },
            startInput: { inputStarts += 1 })
        do {
            try await input.arm(.candidateListening)
            XCTFail("Permission denial must be visible")
        } catch {
            XCTAssertEqual(error as? AcousticSegmentationFailure, .microphonePermissionDenied)
        }
        XCTAssertEqual(inputStarts, 0)
    }

    func testPauseInvalidatesAnOutstandingMicrophonePermissionRequest() async throws {
        var permission: CheckedContinuation<Bool, Never>?
        var inputStarts = 0
        let input = VoiceCoreAcousticSegmenter(requestPermission: {
            await withCheckedContinuation { permission = $0 }
        }, startInput: { inputStarts += 1 })
        let arming = Task { @MainActor in try await input.arm(.candidateListening) }
        for _ in 0..<100 where permission == nil { await Task.yield() }
        let response = try XCTUnwrap(permission)
        await input.disarm()
        response.resume(returning: true)
        do { try await arming.value; XCTFail("Pause must cancel microphone startup") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(inputStarts, 0)
    }

    func testDelayedCaptureIsBoundedAndCannotSilentlyLoseItsBeginning() async throws {
        let input = VoiceCoreAcousticSegmenter(requestPermission: { true }, startInput: {})
        try await input.arm(.candidateListening)
        for _ in 0..<650 { input.ingest(rms: 0.1, samples: Array(repeating: 0.1, count: 1_024)) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-acoustic-overflow-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try input.startValidatedCapture(at: root)) { error in
            XCTAssertEqual(error as? AcousticSegmentationFailure, .captureBufferExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        await input.disarm()
    }
}
