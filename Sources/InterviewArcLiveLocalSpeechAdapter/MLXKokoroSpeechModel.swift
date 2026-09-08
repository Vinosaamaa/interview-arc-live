import Foundation
import InterviewArcLiveCore
import MLXAudioCore
import MLXAudioTTS

/// Uses the reviewed English pronunciation implementation with only verified,
/// Live-owned files. It never invokes the upstream global-cache downloader.
private final class LocalKokoroTextProcessor: TextProcessor, @unchecked Sendable {
    private let english: EnglishG2P

    init(directory: URL) throws {
        english = try EnglishG2P(british: false, directory: directory)
    }

    func prepare() async throws { try Task.checkCancellation() }

    func process(text: String, language: String?) throws -> String {
        try Task.checkCancellation()
        guard language == nil || language == "en-us" || language == "en" else {
            throw LocalInterviewerSpeechError.invalidRequest
        }
        return english.phonemize(text: text).0
    }
}

struct MLXKokoroSpeechModelLoader: LocalSpeechModelLoading {
    func loadModel(from directory: URL) async throws -> any LocalStreamingSpeechModel {
        let processor = try LocalKokoroTextProcessor(directory: directory.appendingPathComponent("g2p"))
        let model = try await KokoroModel.fromModelDirectory(directory, textProcessor: processor)
        guard model.sampleRate == 24_000 else { throw LocalInterviewerSpeechError.incompatibleRuntime }
        _ = try model.loadVoice(named: "af_heart")
        _ = try processor.process(text: "Architecture and reliability.", language: "en-us")
        return MLXKokoroSpeechModel(model: model)
    }
}

private final class MLXKokoroSpeechModel: LocalStreamingSpeechModel, @unchecked Sendable {
    let sampleRate = 24_000
    private let model: KokoroModel
    init(model: KokoroModel) { self.model = model }

    func startGeneration(text: String, profile: InterviewerSpeechProfile) -> any LocalSpeechGeneration {
        KokoroSpeechGeneration(model: model, text: text, profile: profile)
    }
}

/// Sentence-sized generation owns its actual MLX task. Stop joins that task;
/// it never abandons an upstream stream whose producer is still running.
private final class KokoroSpeechGeneration: LocalSpeechGeneration, @unchecked Sendable {
    private let model: KokoroModel
    private let profile: InterviewerSpeechProfile
    private var chunks: ArraySlice<String>
    private var pendingSamples: ArraySlice<Float> = []
    private let lock = NSLock()
    private var task: Task<[Float], Error>?
    private var cancelled = false

    init(model: KokoroModel, text: String, profile: InterviewerSpeechProfile) {
        self.model = model
        self.profile = profile
        chunks = ArraySlice(KokoroTextChunks.split(text).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    func nextSamples() async throws -> [Float]? {
        try Task.checkCancellation()
        guard !lock.withLock({ cancelled }) else { throw CancellationError() }
        if pendingSamples.isEmpty {
            guard let text = chunks.popFirst() else { return nil }
            let model = model
            let profile = profile
            let producer = Task.detached {
                try Task.checkCancellation()
                let audio = try await model.generate(
                    text: text, voice: profile.conditioning, refAudio: nil, refText: nil,
                    language: profile.language, generationParameters: model.defaultGenerationParameters)
                let samples = audio.asArray(Float.self)
                try Task.checkCancellation()
                return samples
            }
            let alreadyCancelled = lock.withLock { task = producer; return cancelled }
            if alreadyCancelled { producer.cancel() }
            defer { lock.withLock { task = nil } }
            let samples = try await withTaskCancellationHandler {
                try await producer.value
            } onCancel: { producer.cancel() }
            guard !samples.isEmpty else { throw LocalInterviewerSpeechError.invalidAudio }
            pendingSamples = ArraySlice(samples)
        }
        try Task.checkCancellation()
        let count = min(pendingSamples.count, 24_000 * 5)
        let next = Array(pendingSamples.prefix(count))
        pendingSamples = pendingSamples.dropFirst(count)
        return next
    }

    func cancelAndWait() async {
        let producer = lock.withLock { cancelled = true; return task }
        producer?.cancel()
        if let producer { _ = await producer.result }
    }
}

/// Keep inputs below Kokoro's phoneme limit without truncating spoken text.
/// Prefer punctuation, then word boundaries; even a long token is bounded.
enum KokoroTextChunks {
    static func split(_ text: String, maximumCharacters: Int = 180) -> [String] {
        precondition(maximumCharacters > 0)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var remaining = text[...]
        var result: [String] = []
        while !remaining.isEmpty {
            let limit = remaining.index(remaining.startIndex, offsetBy: maximumCharacters,
                                        limitedBy: remaining.endIndex) ?? remaining.endIndex
            var end = limit
            if limit != remaining.endIndex {
                let prefix = remaining[..<limit]
                if let boundary = prefix.lastIndex(where: { ".!?;\n".contains($0) })
                    ?? prefix.lastIndex(where: { $0.isWhitespace }) {
                    end = remaining.index(after: boundary)
                }
            }
            let chunk = String(remaining[..<end])
            result.append(chunk)
            remaining = remaining[end...]
        }
        return result
    }
}
