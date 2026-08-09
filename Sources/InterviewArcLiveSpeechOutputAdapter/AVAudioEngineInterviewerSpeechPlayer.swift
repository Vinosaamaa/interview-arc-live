import AVFoundation
import Foundation
import InterviewArcLiveCore

enum AVAudioEngineInterviewerSpeechPlayerError: Error, Equatable, Sendable {
    case invalidFormat
    case emptyChunk
    case nonFiniteSample
    case noActiveStream
    case noScheduledAudio
    case bufferAllocationFailed
    case playbackFailed
}

@MainActor
protocol InterviewerAudioOutputDriving: AnyObject {
    var isPlaying: Bool { get }
    func configure(format: AVAudioFormat) throws
    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void
    )
    func schedule(
        file: AVAudioFile,
        completion: @escaping @Sendable () -> Void
    )
    func play()
    func releaseOutput()
}

@MainActor
private final class AVAudioEngineOutputDriver: InterviewerAudioOutputDriving {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    init() {
        engine.attach(node)
    }

    var isPlaying: Bool { node.isPlaying }

    func configure(format: AVAudioFormat) throws {
        releaseOutput()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AVAudioEngineInterviewerSpeechPlayerError.playbackFailed
        }
    }

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void
    ) {
        node.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { _ in completion() }
    }

    func schedule(
        file: AVAudioFile,
        completion: @escaping @Sendable () -> Void
    ) {
        node.scheduleFile(
            file,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { _ in completion() }
    }

    func play() {
        node.play()
    }

    func releaseOutput() {
        node.stop()
        engine.stop()
        engine.reset()
    }
}

/// Streaming playback Adapter for generated speech. Core owns single-flight
/// policy and cancellation ordering; this MainActor implementation owns the
/// AVAudioEngine graph and never receives transcript text.
@MainActor
public final class AVAudioEngineInterviewerSpeechPlayer: InterviewerSpeechPlaying {
    private enum Mode {
        case idle
        case streaming
        case loadingFile
        case file
    }

    private let audioStore: LiveInterviewerSpeechAudioStore
    private let output: any InterviewerAudioOutputDriving
    private var mode = Mode.idle
    private var operationID = UUID()
    private var pendingBufferCount = 0
    private var hasScheduledAudio = false
    private var streamIsFinishing = false
    private var completion: CheckedContinuation<Void, Error>?

    public init(audioStore: LiveInterviewerSpeechAudioStore) {
        self.audioStore = audioStore
        output = AVAudioEngineOutputDriver()
    }

    init(
        audioStore: LiveInterviewerSpeechAudioStore,
        output: any InterviewerAudioOutputDriving
    ) {
        self.audioStore = audioStore
        self.output = output
    }

    public func beginStreaming(
        sampleRate: Int,
        channelCount: Int
    ) async throws {
        guard sampleRate == PrivateInterviewerWaveStore.sampleRate,
              channelCount == PrivateInterviewerWaveStore.channelCount,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(sampleRate),
                  channels: AVAudioChannelCount(channelCount),
                  interleaved: false
              ) else {
            throw AVAudioEngineInterviewerSpeechPlayerError.invalidFormat
        }
        stopCurrentOperation()
        try configureEngine(format: format)
        mode = .streaming
        operationID = UUID()
        pendingBufferCount = 0
        hasScheduledAudio = false
        streamIsFinishing = false
    }

    public func enqueue(
        _ chunk: InterviewerSpeechPCMChunk
    ) async throws {
        guard mode == .streaming else {
            throw AVAudioEngineInterviewerSpeechPlayerError.noActiveStream
        }
        guard chunk.sampleRate == PrivateInterviewerWaveStore.sampleRate,
              chunk.channelCount == PrivateInterviewerWaveStore.channelCount else {
            throw AVAudioEngineInterviewerSpeechPlayerError.invalidFormat
        }
        guard !chunk.samples.isEmpty else {
            throw AVAudioEngineInterviewerSpeechPlayerError.emptyChunk
        }
        guard chunk.samples.allSatisfy(\.isFinite) else {
            throw AVAudioEngineInterviewerSpeechPlayerError.nonFiniteSample
        }
        guard chunk.samples.count <= Int(AVAudioFrameCount.max),
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(chunk.sampleRate),
                  channels: AVAudioChannelCount(chunk.channelCount),
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(chunk.samples.count)
              ),
              let destination = buffer.floatChannelData?[0] else {
            throw AVAudioEngineInterviewerSpeechPlayerError.bufferAllocationFailed
        }

        chunk.samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            destination.update(from: baseAddress, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        let scheduledOperationID = operationID
        pendingBufferCount += 1
        hasScheduledAudio = true
        output.schedule(buffer: buffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferDidPlay(operationID: scheduledOperationID)
            }
        }
        if !output.isPlaying {
            output.play()
        }
    }

    public func finishStreaming() async throws {
        guard mode == .streaming else {
            throw AVAudioEngineInterviewerSpeechPlayerError.noActiveStream
        }
        guard hasScheduledAudio else {
            stopCurrentOperation()
            throw AVAudioEngineInterviewerSpeechPlayerError.noScheduledAudio
        }
        streamIsFinishing = true
        if pendingBufferCount == 0 {
            completeCurrentOperation()
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
        }
    }

    public func stop() async {
        stopCurrentOperation()
    }

    public func play(
        _ request: InterviewerSpeechPlaybackRequest
    ) async throws {
        stopCurrentOperation()
        let requestedOperationID = UUID()
        operationID = requestedOperationID
        mode = .loadingFile

        let url: URL
        do {
            url = try await audioStore.playbackURL(
                sessionID: request.sessionID,
                artifact: request.artifact
            )
        } catch {
            guard operationID == requestedOperationID,
                  mode == .loadingFile else {
                throw CancellationError()
            }
            stopCurrentOperation()
            throw error
        }
        guard operationID == requestedOperationID,
              mode == .loadingFile else {
            throw CancellationError()
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            stopCurrentOperation()
            throw AVAudioEngineInterviewerSpeechPlayerError.playbackFailed
        }
        guard file.fileFormat.sampleRate
                == Double(PrivateInterviewerWaveStore.sampleRate),
              file.fileFormat.channelCount
                == AVAudioChannelCount(PrivateInterviewerWaveStore.channelCount) else {
            stopCurrentOperation()
            throw AVAudioEngineInterviewerSpeechPlayerError.invalidFormat
        }

        do {
            try configureEngine(format: file.processingFormat)
        } catch {
            stopCurrentOperation()
            throw error
        }
        mode = .file
        let scheduledOperationID = requestedOperationID
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            output.schedule(file: file) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.fileDidPlay(operationID: scheduledOperationID)
                }
            }
            output.play()
        }
    }

    private func configureEngine(format: AVAudioFormat) throws {
        try output.configure(format: format)
    }

    private func bufferDidPlay(operationID completedOperationID: UUID) {
        guard mode == .streaming,
              completedOperationID == operationID else {
            return
        }
        pendingBufferCount = max(0, pendingBufferCount - 1)
        if streamIsFinishing, pendingBufferCount == 0 {
            completeCurrentOperation()
        }
    }

    private func fileDidPlay(operationID completedOperationID: UUID) {
        guard mode == .file,
              completedOperationID == operationID else {
            return
        }
        completeCurrentOperation()
    }

    private func completeCurrentOperation() {
        let waiting = completion
        completion = nil
        mode = .idle
        pendingBufferCount = 0
        hasScheduledAudio = false
        streamIsFinishing = false
        output.releaseOutput()
        waiting?.resume()
    }

    private func stopCurrentOperation() {
        let waiting = completion
        completion = nil
        operationID = UUID()
        mode = .idle
        pendingBufferCount = 0
        hasScheduledAudio = false
        streamIsFinishing = false
        output.releaseOutput()
        waiting?.resume(throwing: CancellationError())
    }
}
