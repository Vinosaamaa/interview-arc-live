import AVFoundation
import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore

/// Production acoustic-segmentation Adapter. Voice processing supplies echo
/// cancellation against this engine's output; only the cleaned near-end signal
/// is measured and recorded. A bounded in-memory onset buffer spans durable
/// capture authorization; the same input tap then writes the private M4A.
@MainActor
public final class VoiceCoreAcousticSegmenter: AcousticSegmenting, VoiceCoreRecordingDriving {
    public static let speechStartFrameCount = 8
    public static let bargeInStartFrameCount = 12
    public static let speechEndFrameCount = 18
    public static let rmsStartThreshold: Float = 0.018
    public static let rmsEndThreshold: Float = 0.010

    private let engine: AVAudioEngine
    private let sharesEngine: Bool
    private let requestPermission: @MainActor () async -> Bool
    private let startInputOverride: (@MainActor () throws -> Void)?
    private var generation = 0
    private var pendingSpeechSamples: [Float]?
    private var pendingCaptureOverflowed = false
    static let maximumPendingCaptureMilliseconds = 15_000
    private var captureFile: AVAudioFile?
    private var captureURL: URL?
    private var capturedFrameCount: Int64 = 0
    private var captureSampleRate: Double = 44_100
    private var capturePeakRMS: Float = 0
    private var captureWriteFailed = false
    private var meteringHistory: [Float] = []
    var onUnexpectedTermination: (@MainActor () -> Void)?
    var onMetering: (@MainActor (VoiceCoreRecordingMetering) -> Void)?
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
        requestPermission = Self.requestMicrophonePermission
        startInputOverride = nil
    }

    init(requestPermission: @escaping @MainActor () async -> Bool,
         startInput: (@MainActor () throws -> Void)? = nil) {
        engine = AVAudioEngine()
        sharesEngine = false
        self.requestPermission = requestPermission
        startInputOverride = startInput
    }

    private static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    public func setEventHandler(
        _ handler: (@MainActor @Sendable (AcousticSegmentationEvent) -> Void)?
    ) {
        self.handler = handler
    }

    public func arm(_ mode: AcousticSegmentationMode) async throws {
        let preserveSpeech = isSpeechActive && Self.isLive(self.mode) && Self.isLive(mode)
        try await ensureMicrophone()
        self.mode = mode
        if !preserveSpeech {
            consecutiveSpeechFrames = 0
            consecutiveSilenceFrames = 0
            isSpeechActive = false
        }
    }

    public func disarm() async {
        generation += 1
        let preserveOutput = sharesEngine && mode == .bargeInDetection
        mode = .disarmed
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
        isSpeechActive = false
        pendingSpeechSamples = nil
        pendingCaptureOverflowed = false
        preRoll.removeAll(keepingCapacity: true)
        // An authorized recording is finalized by the coordinator immediately
        // after Pause. Keep its input alive until stop has preserved the file.
        if captureFile == nil { releaseMicrophone(preserveOutput: preserveOutput) }
    }

    private func ensureMicrophone() async throws {
        let startingGeneration = generation
        guard await requestPermission() else {
            throw AcousticSegmentationFailure.microphonePermissionDenied
        }
        guard startingGeneration == generation else { throw CancellationError() }
        if let startInputOverride {
            try startInputOverride()
            return
        }
        try installTapIfNeeded()
        if !engine.isRunning {
            do { try engine.start() }
            catch {
                releaseMicrophone()
                throw AcousticSegmentationFailure.inputUnavailable
            }
        }
    }

    private func releaseMicrophone(preserveOutput: Bool = false) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // The speech player may own active output on the shared engine. Its
        // output stays connected; stopping and starting preserves that graph.
        if !preserveOutput, engine.isRunning { engine.stop() }
    }

    public func takeBoundedPreRoll() -> AcousticPreRoll? {
        guard !preRoll.isEmpty else { return nil }
        return AcousticPreRoll(
            sampleRate: tapSampleRate,
            channelCount: 1,
            samples: preRoll
        )
    }

    private func installTapIfNeeded() throws {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Voice processing is best-effort echo cancellation. Energy VAD
            // still runs on the near-end buffer if the hardware rejects it.
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AcousticSegmentationFailure.inputUnavailable
        }
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

    func ingest(rms: Float, samples: [Float]) {
        guard rms.isFinite, samples.allSatisfy(\.isFinite) else {
            failActiveCapture()
            return
        }
        if captureFile != nil {
            do { try writeCaptureSamples(samples) }
            catch { failActiveCapture() }
        } else if pendingSpeechSamples != nil {
            let limit = Int(tapSampleRate * Double(Self.maximumPendingCaptureMilliseconds) / 1_000)
            if (pendingSpeechSamples?.count ?? 0) + samples.count <= limit {
                pendingSpeechSamples?.append(contentsOf: samples)
            } else {
                pendingCaptureOverflowed = true
            }
        }
        guard mode != .disarmed else { return }
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
                if captureFile == nil {
                    pendingSpeechSamples = preRoll
                    pendingCaptureOverflowed = false
                }
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

    func start(at destinationURL: URL,
               captureBackendDidStart: @escaping @MainActor () -> Void) async throws {
        guard captureFile == nil else { throw VoiceCoreSegmentRecorderError.captureAlreadyActive }
        try await ensureMicrophone()
        try startValidatedCapture(at: destinationURL)
        captureBackendDidStart()
    }

    // The microphone and synthetic PCM tests use the same writer. Files are
    // created only after the coordinator has persisted capture authorization.
    func startValidatedCapture(at destinationURL: URL) throws {
        guard captureFile == nil else { throw VoiceCoreSegmentRecorderError.captureAlreadyActive }
        guard !pendingCaptureOverflowed else { throw AcousticSegmentationFailure.captureBufferExceeded }
        captureSampleRate = tapSampleRate
        let file = try AVAudioFile(forWriting: destinationURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: captureSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        captureFile = file
        captureURL = destinationURL
        capturedFrameCount = 0
        capturePeakRMS = 0
        captureWriteFailed = false
        meteringHistory = []
        let beginning = pendingSpeechSamples ?? (mode == .disarmed ? [] : preRoll)
        pendingSpeechSamples = nil
        do { try writeCaptureSamples(beginning) }
        catch {
            captureFile = nil
            captureURL = nil
            throw error
        }
    }

    func stop() throws -> RecordedCapture {
        guard let url = captureURL, captureFile != nil else {
            throw VoiceCoreSegmentRecorderError.noActiveCapture
        }
        // Releasing AVAudioFile closes its encoder before inspection/adoption.
        captureFile = nil
        captureURL = nil
        pendingSpeechSamples = nil
        pendingCaptureOverflowed = false
        if mode == .disarmed { releaseMicrophone() }
        onMetering?(.idle)
        return RecordedCapture(
            url: url, duration: Double(capturedFrameCount) / captureSampleRate,
            writtenFrameCount: capturedFrameCount,
            writeErrorDescription: captureWriteFailed ? "audio_write_failed" : nil,
            peakPowerDecibels: 20 * log10(max(capturePeakRMS, 0.000001))
        )
    }

    private func writeCaptureSamples(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let file = captureFile, samples.count <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw AcousticSegmentationFailure.inputUnavailable
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        capturedFrameCount += Int64(samples.count)
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        capturePeakRMS = max(capturePeakRMS, rms)
        meteringHistory.append(min(1, max(0, (20 * log10(max(rms, 0.000001)) + 60) / 60)))
        if meteringHistory.count > 50 { meteringHistory.removeFirst(meteringHistory.count - 50) }
        onMetering?(.init(powerHistory: meteringHistory,
            elapsedSeconds: Double(capturedFrameCount) / captureSampleRate))
    }

    private func failActiveCapture() {
        guard captureFile != nil, !captureWriteFailed else { return }
        captureWriteFailed = true
        onUnexpectedTermination?()
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
