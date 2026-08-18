import AVFoundation
import Foundation
import InterviewArcLiveCore

/// Production acoustic-segmentation Adapter. Voice processing supplies echo
/// cancellation against this engine's output; only the cleaned near-end signal
/// is measured. Raw samples never leave this Adapter except as a bounded
/// pre-roll handed to capture.
@MainActor
public final class VoiceCoreAcousticSegmenter: AcousticSegmenting {
    public static let speechStartFrameCount = 8
    public static let bargeInStartFrameCount = 12
    public static let speechEndFrameCount = 18
    public static let rmsStartThreshold: Float = 0.018
    public static let rmsEndThreshold: Float = 0.010

    private let engine: AVAudioEngine
    private let sharesEngine: Bool
    private var handler: (@MainActor @Sendable (AcousticSegmentationEvent) -> Void)?
    private var mode: AcousticSegmentationMode = .disarmed
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0
    private var isSpeechActive = false
    private var tapInstalled = false
    private var tapSampleRate: Double = 44_100
    private var preRoll: [Float] = []

    public init(
        engine: AVAudioEngine = AVAudioEngine(),
        sharesEngine: Bool = false
    ) {
        self.engine = engine
        self.sharesEngine = sharesEngine
    }

    public func setEventHandler(
        _ handler: (@MainActor @Sendable (AcousticSegmentationEvent) -> Void)?
    ) {
        self.handler = handler
    }

    public func arm(_ mode: AcousticSegmentationMode) async {
        let preserveSpeech =
            isSpeechActive
            && Self.isLive(self.mode)
            && Self.isLive(mode)
        self.mode = mode
        if !preserveSpeech {
            consecutiveSpeechFrames = 0
            consecutiveSilenceFrames = 0
            isSpeechActive = false
        }
        installTapIfNeeded()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                self.mode = .disarmed
            }
        }
    }

    public func disarm() async {
        mode = .disarmed
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
        isSpeechActive = false
        guard !sharesEngine else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        preRoll.removeAll(keepingCapacity: true)
        if engine.isRunning {
            engine.stop()
        }
    }

    public func takeBoundedPreRoll() -> AcousticPreRoll? {
        guard !preRoll.isEmpty else { return nil }
        return AcousticPreRoll(
            sampleRate: tapSampleRate,
            channelCount: 1,
            samples: preRoll
        )
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Voice processing is best-effort echo cancellation. Energy VAD
            // still runs on the near-end buffer if the hardware rejects it.
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        tapSampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self] buffer, _ in
            let rms = Self.rootMeanSquare(buffer)
            let samples = Self.channelSamples(buffer)
            Task { @MainActor [weak self] in
                self?.ingest(rms: rms, samples: samples)
            }
        }
        tapInstalled = true
    }

    private func ingest(rms: Float, samples: [Float]) {
        appendPreRoll(samples)
        switch mode {
        case .disarmed:
            return
        case .candidateListening, .bargeInDetection:
            break
        }

        let startFrames = mode == .bargeInDetection
            ? Self.bargeInStartFrameCount
            : Self.speechStartFrameCount

        if rms >= Self.rmsStartThreshold {
            consecutiveSpeechFrames += 1
            consecutiveSilenceFrames = 0
            if !isSpeechActive, consecutiveSpeechFrames >= startFrames {
                isSpeechActive = true
                handler?(.speechStarted)
            }
            return
        }

        if rms <= Self.rmsEndThreshold {
            consecutiveSilenceFrames += 1
            consecutiveSpeechFrames = 0
            if mode == .bargeInDetection {
                return
            }
            if isSpeechActive,
               consecutiveSilenceFrames >= Self.speechEndFrameCount {
                isSpeechActive = false
                handler?(.speechEnded)
            }
        }
    }

    private func appendPreRoll(_ samples: [Float]) {
        guard !samples.isEmpty, tapSampleRate > 0 else { return }
        preRoll.append(contentsOf: samples)
        let maximumSampleCount = Int(
            tapSampleRate * Double(AcousticPreRoll.maximumDurationMilliseconds) / 1_000
        )
        if preRoll.count > maximumSampleCount {
            preRoll.removeFirst(preRoll.count - maximumSampleCount)
        }
    }

    private static func isLive(_ mode: AcousticSegmentationMode) -> Bool {
        switch mode {
        case .candidateListening, .bargeInDetection:
            true
        case .disarmed:
            false
        }
    }

    private static func channelSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?.pointee else { return [] }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    private static func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }
}
