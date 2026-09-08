import Foundation

/// Public, immutable provenance for the only Qwen snapshot this Adapter may
/// install or load. Model-relative paths are public upstream identities; local
/// filesystem paths never enter this value.
public enum Qwen3TTSProvenance {
    public static let providerID = "local-qwen3-tts"
    public static let packageRepository = "Vinosaamaa/mlx-audio-swift"
    public static let packageVersion = "0.1.3"
    public static let packageRevision = "a228dc056c6b298a2f5aff7f10e3aed537577fa0"
    public static let packageUpstreamRevision = "d302a5c6080d2bb97bae38c7418f82abb76013b6"

    public static let modelID = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
    public static let modelRevision = "049ef77fe8816b536193c0c25f9a214d17921282"
    public static let modelLicenseIdentifier = "Apache-2.0"
    public static let modelLicenseURL = URL(
        string: "https://www.apache.org/licenses/LICENSE-2.0"
    )!
    public static let modelRevisionURL = URL(
        string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit/tree/049ef77fe8816b536193c0c25f9a214d17921282"
    )!

    public static let snapshotByteCount: Int64 = 1_973_575_388
    public static let snapshotSizeLabel = "1.838 GiB"
    public static let minimumFreeByteCount: Int64 = 4 * 1_024 * 1_024 * 1_024
    public static let destinationClass = "Live-specific Application Support model storage"

    static let publicSnapshot = LocalSpeechSnapshotManifest(
        repositoryID: modelID,
        revision: modelRevision,
        files: [
            .init(
                path: ".gitattributes",
                byteCount: 1_519,
                sha256: "11ad7efa24975ee4b0c3c3a38ed18737f0658a5f75a0a96787b576a78a023361"
            ),
            .init(
                path: "README.md",
                byteCount: 1_068,
                sha256: "43eb391246ca355e5eaa3fa74b8f9a433dd48d68cdec1e04321f9c1b2c9fd855"
            ),
            .init(
                path: "config.json",
                byteCount: 6_058,
                sha256: "2eea3665564268139c3beb8d497fd3c2e4524e9eed5452836cdf1de96ed3cdbd"
            ),
            .init(
                path: "generation_config.json",
                byteCount: 245,
                sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"
            ),
            .init(
                path: "merges.txt",
                byteCount: 1_671_839,
                sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"
            ),
            .init(
                path: "model.safetensors",
                byteCount: 1_286_743_170,
                sha256: "3bcb2c4a127e6243e81a30b7126c7865f686d3559de4f938e5d3b150c6a9560d"
            ),
            .init(
                path: "model.safetensors.index.json",
                byteCount: 71_447,
                sha256: "0c92041960fa189cf35ae538c8d9ca07c468edddd0c9bb52274c5d4d287a860b"
            ),
            .init(
                path: "preprocessor_config.json",
                byteCount: 127,
                sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"
            ),
            .init(
                path: "speech_tokenizer/config.json",
                byteCount: 2_336,
                sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"
            ),
            .init(
                path: "speech_tokenizer/configuration.json",
                byteCount: 76,
                sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"
            ),
            .init(
                path: "speech_tokenizer/model.safetensors",
                byteCount: 682_293_092,
                sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"
            ),
            .init(
                path: "speech_tokenizer/preprocessor_config.json",
                byteCount: 234,
                sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"
            ),
            .init(
                path: "tokenizer_config.json",
                byteCount: 7_344,
                sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"
            ),
            .init(
                path: "vocab.json",
                byteCount: 2_776_833,
                sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
            ),
        ]
    )
}

struct LocalSpeechSnapshotFile: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

struct LocalSpeechSnapshotManifest: Equatable, Sendable {
    let repositoryID: String
    let revision: String
    let files: [LocalSpeechSnapshotFile]

    var byteCount: Int64 {
        var total: Int64 = 0
        for file in files {
            guard file.byteCount > 0 else { return -1 }
            let (next, overflow) = total.addingReportingOverflow(file.byteCount)
            guard !overflow else { return -1 }
            total = next
        }
        return total
    }

    var fingerprint: String {
        let canonical = files
            .sorted { $0.path < $1.path }
            .map { "\($0.path)\u{0}\($0.byteCount)\u{0}\($0.sha256)" }
            .joined(separator: "\n")
        return LocalSpeechSHA256.string(Data(canonical.utf8))
    }
}
