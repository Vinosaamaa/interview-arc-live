import Combine
import Foundation
import InterviewArcVoiceCore

public struct VoiceCoreRecordingMetering: Equatable, Sendable {
    public var powerHistory: [Float]
    public var elapsedSeconds: TimeInterval

    public static let idle = VoiceCoreRecordingMetering(
        powerHistory: [],
        elapsedSeconds: 0
    )

    public init(powerHistory: [Float], elapsedSeconds: TimeInterval) {
        self.powerHistory = powerHistory
        self.elapsedSeconds = elapsedSeconds
    }
}

@MainActor
protocol VoiceCoreRecordingDriving: AnyObject {
    var onUnexpectedTermination: (@MainActor () -> Void)? { get set }
    var onMetering: (@MainActor (VoiceCoreRecordingMetering) -> Void)? { get set }

    func start(
        at destinationURL: URL,
        captureBackendDidStart: @escaping @MainActor () -> Void
    ) async throws

    func stop() throws -> RecordedCapture
}

@MainActor
final class AnswerRecorderDriver: VoiceCoreRecordingDriving {
    private let recorder: AnswerRecorder
    private var meteringCancellable: AnyCancellable?

    convenience init() {
        self.init(recorder: AnswerRecorder())
    }

    init(recorder: AnswerRecorder) {
        self.recorder = recorder
        recorder.onUnexpectedTermination = { [weak self] in
            self?.endMetering()
            self?.unexpectedTerminationClient?()
        }
    }

    private var unexpectedTerminationClient: (@MainActor () -> Void)?

    var onUnexpectedTermination: (@MainActor () -> Void)? {
        get { unexpectedTerminationClient }
        set { unexpectedTerminationClient = newValue }
    }

    var onMetering: (@MainActor (VoiceCoreRecordingMetering) -> Void)?

    func start(
        at destinationURL: URL,
        captureBackendDidStart: @escaping @MainActor () -> Void
    ) async throws {
        beginMetering()
        do {
            try await recorder.start(
                at: destinationURL,
                captureBackendDidStart: captureBackendDidStart
            )
        } catch {
            endMetering()
            throw error
        }
    }

    func stop() throws -> RecordedCapture {
        defer { endMetering() }
        return try recorder.stop()
    }

    private func beginMetering() {
        meteringCancellable = Publishers.CombineLatest(
            recorder.$powerHistory,
            recorder.$elapsedSeconds
        )
        .sink { [weak self] history, elapsed in
            self?.onMetering?(
                VoiceCoreRecordingMetering(
                    powerHistory: history,
                    elapsedSeconds: elapsed
                )
            )
        }
    }

    private func endMetering() {
        meteringCancellable?.cancel()
        meteringCancellable = nil
        onMetering?(.idle)
    }
}
