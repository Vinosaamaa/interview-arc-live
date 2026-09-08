import Foundation

/// Local speech-versus-silence detection performed on-device. The Session
/// Module never sees raw audio; it only observes bounded result codes.
public enum AcousticSegmentationResultCode: String, Sendable, Equatable {
    case speechStarted = "speech_started"
    case speechEnded = "speech_ended"
    case ignoredNoise = "ignored_noise"
    case disarmed
}

public enum AcousticSegmentationMode: String, Sendable, Equatable {
    case candidateListening = "candidate_listening"
    case bargeInDetection = "barge_in_detection"
    case disarmed
}

public enum AcousticSegmentationEvent: Sendable, Equatable {
    case speechStarted
    case speechEnded
    case ignoredNoise
}

/// Bounded near-end PCM captured before speech-start confirmation. Raw
/// samples never enter Session state or traces; only duration counts do.
public struct AcousticPreRoll: Sendable, Equatable {
    public static let maximumDurationMilliseconds = 400

    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]

    public init(sampleRate: Double, channelCount: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
    }

    public var durationMilliseconds: Int {
        guard sampleRate > 0 else { return 0 }
        return Int((Double(samples.count) / sampleRate) * 1_000)
    }
}

public enum AcousticSegmentationFailure: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case inputUnavailable
    case captureBufferExceeded
}

/// Narrow local-audio Seam for Continuous Conversation. Production uses a
/// VoiceCore-backed Adapter; tests inject a deterministic Adapter.
@MainActor
public protocol AcousticSegmenting: AnyObject {
    func setEventHandler(
        _ handler: (@MainActor @Sendable (AcousticSegmentationEvent) -> Void)?
    )

    func arm(_ mode: AcousticSegmentationMode) async throws

    func disarm() async

    func takeBoundedPreRoll() -> AcousticPreRoll?
}

extension AcousticSegmenting {
    public func takeBoundedPreRoll() -> AcousticPreRoll? { nil }
}

/// Test Adapter that emits speech boundaries only when a test asks. It never
/// touches a microphone or audio buffer.
@MainActor
public final class DeterministicAcousticSegmenter: AcousticSegmenting {
    public private(set) var mode: AcousticSegmentationMode = .disarmed
    public private(set) var armCount = 0
    public private(set) var disarmCount = 0
    public var preRoll: AcousticPreRoll?

    private var handler: (@MainActor @Sendable (AcousticSegmentationEvent) -> Void)?

    public init() {}

    public func setEventHandler(
        _ handler: (@MainActor @Sendable (AcousticSegmentationEvent) -> Void)?
    ) {
        self.handler = handler
    }

    public func arm(_ mode: AcousticSegmentationMode) async {
        self.mode = mode
        armCount += 1
    }

    public func disarm() async {
        mode = .disarmed
        disarmCount += 1
    }

    public func emit(_ event: AcousticSegmentationEvent) {
        handler?(event)
    }

    public func takeBoundedPreRoll() -> AcousticPreRoll? {
        preRoll
    }
}
