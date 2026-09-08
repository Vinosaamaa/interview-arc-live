import Foundation
import HuggingFace

/// The only network-capable model downloader. It asks swift-huggingface for
/// the immutable cache snapshot, then explicitly materializes every allowlisted
/// path. The package's destination copier skips hidden files; using it would
/// silently omit the pinned `.gitattributes` entry.
struct HuggingFaceLocalSpeechSnapshotDownloader: LocalSpeechSnapshotDownloading {
    func downloadSnapshot(
        manifest: LocalSpeechSnapshotManifest,
        destination: URL,
        cacheRoot: URL,
        progress: @escaping @Sendable (LocalSpeechModelStoreProgress) -> Void
    ) async throws {
        guard let repository = Repo.ID(rawValue: manifest.repositoryID) else {
            throw LocalSpeechModelStoreFailure.downloadFailed
        }

        let client = HubClient(
            host: HubClient.defaultHost,
            bearerToken: nil,
            cache: HubCache(cacheDirectory: cacheRoot)
        )
        let expectedBytes = manifest.byteCount

        do {
            let cachedSnapshot = try await client.downloadSnapshot(
                of: repository,
                kind: .model,
                revision: manifest.revision,
                matching: manifest.files.map(\.path),
                localFilesOnly: false,
                maxConcurrentDownloads: 2,
                progressHandler: { observed in
                    progress(
                        LocalSpeechModelStoreProgress(
                            stage: .downloading,
                            completedBytes: min(
                                max(observed.completedUnitCount, 0),
                                expectedBytes
                            ),
                            totalBytes: expectedBytes
                        )
                    )
                }
            )
            try Task.checkCancellation()
            try await LocalSpeechSnapshotMaterializationExecutor.run(
                manifest: manifest,
                cachedSnapshot: cachedSnapshot,
                cacheRoot: cacheRoot,
                destination: destination
            )
        } catch is CancellationError {
            throw LocalSpeechModelStoreFailure.cancelled
        } catch let failure as LocalSpeechModelStoreFailure {
            throw failure
        } catch {
            throw LocalSpeechModelStoreFailure.downloadFailed
        }
    }
}

struct LocalSpeechSnapshotMaterializer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func materialize(
        manifest: LocalSpeechSnapshotManifest,
        cachedSnapshot: URL,
        cacheRoot: URL,
        destination: URL,
        cancellationCheck: @escaping @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) throws {
        try validateDirectory(cachedSnapshot, permitsSymlink: false)
        try validateDirectory(cacheRoot, permitsSymlink: false)
        try validateDirectory(destination, permitsSymlink: false)

        let cacheBoundary = cacheRoot.resolvingSymlinksInPath().standardizedFileURL
        let snapshotBoundary = cachedSnapshot.standardizedFileURL
        guard isDescendant(snapshotBoundary, of: cacheRoot.standardizedFileURL) else {
            throw LocalSpeechModelStoreFailure.invalidSnapshotRoot
        }

        for file in manifest.files {
            try cancellationCheck()
            guard isSafeRelativePath(file.path) else {
                throw LocalSpeechModelStoreFailure.unexpectedSnapshotShape
            }

            let source = cachedSnapshot.appendingPathComponent(file.path).standardizedFileURL
            let target = destination.appendingPathComponent(file.path).standardizedFileURL
            guard isDescendant(source, of: snapshotBoundary),
                  isDescendant(target, of: destination.standardizedFileURL) else {
                throw LocalSpeechModelStoreFailure.invalidSnapshotRoot
            }

            let sourceValues = try source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard sourceValues.isRegularFile == true || sourceValues.isSymbolicLink == true else {
                throw LocalSpeechModelStoreFailure.missingFile
            }

            let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(resolvedSource, of: cacheBoundary) else {
                throw LocalSpeechModelStoreFailure.symbolicLinkRejected
            }
            let resolvedValues = try resolvedSource.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard resolvedValues.isRegularFile == true,
                  resolvedValues.isSymbolicLink != true else {
                throw LocalSpeechModelStoreFailure.symbolicLinkRejected
            }

            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard !fileManager.fileExists(atPath: target.path) else {
                throw LocalSpeechModelStoreFailure.unexpectedSnapshotShape
            }
            try fileManager.copyItem(at: resolvedSource, to: target)
            try cancellationCheck()
        }
    }

    private func validateDirectory(_ url: URL, permitsSymlink: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true else {
            throw LocalSpeechModelStoreFailure.invalidSnapshotRoot
        }
        if !permitsSymlink, values.isSymbolicLink == true {
            throw LocalSpeechModelStoreFailure.symbolicLinkRejected
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }
}

/// Runs blocking multi-gigabyte cache materialization away from Swift's
/// cooperative executor. Cancellation is checked between allowlisted files;
/// a single in-flight filesystem copy remains atomic from this layer's view.
private enum LocalSpeechSnapshotMaterializationExecutor {
    private static let queue = DispatchQueue(
        label: "interview-arc-live.qwen-snapshot-materialization",
        qos: .utility
    )

    static func run(
        manifest: LocalSpeechSnapshotManifest,
        cachedSnapshot: URL,
        cacheRoot: URL,
        destination: URL
    ) async throws {
        let cancellation = MaterializationCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try LocalSpeechSnapshotMaterializer().materialize(
                            manifest: manifest,
                            cachedSnapshot: cachedSnapshot,
                            cacheRoot: cacheRoot,
                            destination: destination,
                            cancellationCheck: cancellation.check
                        )
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class MaterializationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    func check() throws {
        if lock.withLock({ isCancelled }) {
            throw CancellationError()
        }
    }
}
