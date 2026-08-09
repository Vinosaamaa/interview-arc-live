import Foundation
import InterviewArcVoiceCore

@MainActor
protocol VoiceCoreRecordingDriving: AnyObject {
    var onUnexpectedTermination: (@MainActor () -> Void)? { get set }

    func start(
        at destinationURL: URL,
        captureBackendDidStart: @escaping @MainActor () -> Void
    ) async throws

    func stop() throws -> RecordedCapture
}

@MainActor
final class AnswerRecorderDriver: VoiceCoreRecordingDriving {
    private let recorder: AnswerRecorder

    convenience init() {
        self.init(recorder: AnswerRecorder())
    }

    init(recorder: AnswerRecorder) {
        self.recorder = recorder
    }

    var onUnexpectedTermination: (@MainActor () -> Void)? {
        get { recorder.onUnexpectedTermination }
        set { recorder.onUnexpectedTermination = newValue }
    }

    func start(
        at destinationURL: URL,
        captureBackendDidStart: @escaping @MainActor () -> Void
    ) async throws {
        try await recorder.start(
            at: destinationURL,
            captureBackendDidStart: captureBackendDidStart
        )
    }

    func stop() throws -> RecordedCapture {
        try recorder.stop()
    }
}
