import Foundation
import InterviewArcLiveCore

public enum LocalSpeechEngine: String, CaseIterable, Codable, Sendable {
    case qwen
    case kokoro

    public var displayName: String { self == .qwen ? "Qwen" : "Kokoro" }
    public var downloadSizeLabel: String { self == .qwen ? "1.838 GiB" : "321.2 MiB" }
    public var minimumFreeSpaceLabel: String { self == .qwen ? "4 GiB" : "1 GiB" }
    public var minimumFreeByteCount: Int64 {
        self == .qwen ? Qwen3TTSProvenance.minimumFreeByteCount : KokoroProvenance.minimumFreeByteCount
    }
    public var provenance: InterviewerSpeechProvenance {
        switch self {
        case .qwen:
            InterviewerSpeechProvenance(
                providerID: Qwen3TTSProvenance.providerID, modelID: Qwen3TTSProvenance.modelID,
                modelRevision: Qwen3TTSProvenance.modelRevision, profile: .maraV1)
        case .kokoro:
            InterviewerSpeechProvenance(
                providerID: KokoroProvenance.providerID, modelID: KokoroProvenance.modelID,
                modelRevision: KokoroProvenance.modelRevision, profile: Self.kokoroProfile)
        }
    }

    // Kokoro uses the fixed af_heart voice, English phonemes, and speed 1.0.
    // The remaining common fields are recorded neutral values, not Qwen sampling settings.
    static let kokoroProfile = try! InterviewerSpeechProfile(
        profileID: "kokoro-af-heart-en-us-speed-1-v1", language: "en-us", conditioning: "af_heart",
        maxTokens: 510, temperature: 0, topP: 1, topK: 0, minP: 0,
        repetitionPenalty: 1, repetitionContextSize: 20, streamingInterval: 0.5)
}
