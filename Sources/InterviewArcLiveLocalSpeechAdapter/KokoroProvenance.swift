import Foundation

public enum KokoroProvenance {
    public static let providerID = "local-kokoro"
    public static let modelID = "mlx-community/Kokoro-82M-bf16"
    public static let modelRevision = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"
    public static let snapshotByteCount: Int64 = 336_759_320
    public static let minimumFreeByteCount: Int64 = 1_024 * 1_024 * 1_024
    static let pronunciationRepository = "beshkenadze/kitten-tts-g2p"
    static let pronunciationRevision = "9c692b92682d959d9013a9cfe6a49541997add18"

    static let modelSnapshot = LocalSpeechSnapshotManifest(
        repositoryID: modelID, revision: modelRevision, files: [
            .init(path: "config.json", byteCount: 2351, sha256: "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"),
            .init(path: "kokoro-v1_0.safetensors", byteCount: 327115152, sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"),
            .init(path: "voices/af_heart.safetensors", byteCount: 522320, sha256: "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094"),
        ]
    )
    static let pronunciationSnapshot = LocalSpeechSnapshotManifest(
        repositoryID: pronunciationRepository, revision: pronunciationRevision, files: [
            .init(path: "us_bart.safetensors", byteCount: 3011692, sha256: "dc4a02e62d4fcb4bb4097ecf00db89b8e1a12a549a52ab6adfbba220b80a55c5"),
            .init(path: "us_bart_config.json", byteCount: 1257, sha256: "8deb3537fb29c63cd9f20d75515ae06e4c92f1b6db0703a2d45bca95b33a53a4"),
            .init(path: "us_gold.json", byteCount: 3001196, sha256: "8507f89840f0813b10cf584740942f58e9cc9ad3660e24088b442ab0a6b126be"),
            .init(path: "us_silver.json", byteCount: 3105352, sha256: "ea0e1abca0c9b18fb0d3402034633a337154a3153e9a9f49f97d668c908e140c"),
        ]
    )
    /// Combined allowlist covers the model, selected voice, and all pronunciation assets.
    static let publicSnapshot = LocalSpeechSnapshotManifest(
        repositoryID: modelID, revision: modelRevision,
        files: modelSnapshot.files + pronunciationSnapshot.files.map {
            LocalSpeechSnapshotFile(path: "g2p/" + $0.path, byteCount: $0.byteCount, sha256: $0.sha256)
        }
    )
}

struct KokoroSnapshotDownloader: LocalSpeechSnapshotDownloading {
    func downloadSnapshot(
        manifest: LocalSpeechSnapshotManifest,
        destination: URL,
        cacheRoot: URL,
        progress: @escaping @Sendable (LocalSpeechModelStoreProgress) -> Void
    ) async throws {
        guard manifest == KokoroProvenance.publicSnapshot else {
            throw LocalSpeechModelStoreFailure.unexpectedSnapshotShape
        }
        let downloader = HuggingFaceLocalSpeechSnapshotDownloader()
        let model = KokoroProvenance.modelSnapshot
        try await downloader.downloadSnapshot(
            manifest: model, destination: destination,
            cacheRoot: cacheRoot.appendingPathComponent("model"),
            progress: { update in
                progress(.init(stage: .downloading, completedBytes: update.completedBytes,
                               totalBytes: manifest.byteCount))
            }
        )
        try Task.checkCancellation()
        let pronunciationRoot = destination.appendingPathComponent("g2p", isDirectory: true)
        try FileManager.default.createDirectory(at: pronunciationRoot,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try await downloader.downloadSnapshot(
            manifest: KokoroProvenance.pronunciationSnapshot, destination: pronunciationRoot,
            cacheRoot: cacheRoot.appendingPathComponent("pronunciation"),
            progress: { update in
                progress(.init(stage: .downloading,
                               completedBytes: model.byteCount + update.completedBytes,
                               totalBytes: manifest.byteCount))
            }
        )
    }
}
