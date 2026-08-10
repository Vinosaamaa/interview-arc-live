import CryptoKit
import Foundation

enum QwenModelStoreReadiness: Equatable, Sendable {
    case notInstalled
    case preparing(QwenModelStoreProgress)
    case ready(modelDirectory: URL)
    case unavailable(QwenModelStoreFailure)
}

enum QwenModelStoreFailure: String, Error, Equatable, Sendable {
    case invalidStorageRoot
    case insufficientFreeSpace
    case preparationInProgress
    case downloadFailed
    case cancelled
    case invalidSnapshotRoot
    case symbolicLinkRejected
    case unexpectedSnapshotShape
    case missingFile
    case wrongFileSize
    case hashMismatch
    case invalidVerificationReceipt
    case derivedTokenizerInvalid
    case loaderValidationFailed
    case storageFailure
}

struct QwenModelStoreProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case checkingStorage
        case downloading
        case verifying
        case promoting
    }

    let stage: Stage
    let completedBytes: Int64
    let totalBytes: Int64
}

protocol QwenSnapshotDownloading: Sendable {
    func downloadSnapshot(
        manifest: QwenSnapshotManifest,
        destination: URL,
        cacheRoot: URL,
        progress: @escaping @Sendable (QwenModelStoreProgress) -> Void
    ) async throws
}

protocol QwenFreeSpaceReading: Sendable {
    func availableBytes(for location: URL) throws -> Int64
}

struct FoundationQwenFreeSpaceReader: QwenFreeSpaceReading {
    func availableBytes(for location: URL) throws -> Int64 {
        let fileManager = FileManager.default
        var existing = location.standardizedFileURL
        while !fileManager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else {
                throw QwenModelStoreFailure.invalidStorageRoot
            }
            existing = parent
        }

        let values = try existing.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let attributes = try fileManager.attributesOfFileSystem(forPath: existing.path)
        guard let number = attributes[.systemFreeSize] as? NSNumber else {
            throw QwenModelStoreFailure.storageFailure
        }
        return number.int64Value
    }
}

/// Deep Module for the exact public model revision. Network/cache layout,
/// staged loader validation, receipts, atomic promotion, and scoped deletion
/// stay behind this small Interface.
actor QwenModelStore {
    static let verificationReceiptName = ".interview-arc-live-verification.json"
    static let derivedReceiptName = ".interview-arc-live-derived-runtime.json"
    static let derivedTokenizerName = "tokenizer.json"

    /// Authoritative byte count for this store's exact manifest. Keeping the
    /// value at the storage boundary prevents provider progress from drifting
    /// from an injected or future snapshot manifest.
    nonisolated let snapshotByteCount: Int64

    private let modelRoot: URL
    private let privateStorageRoot: URL
    private let manifest: QwenSnapshotManifest
    private let downloader: any QwenSnapshotDownloading
    private let freeSpaceReader: any QwenFreeSpaceReading
    private let fileManager: FileManager
    private let minimumFreeBytes: Int64
    private let postReplacementValidation: @Sendable (URL, URL) throws -> Void

    private var activePreparationID: UUID?
    private var latestProgress: QwenModelStoreProgress?
    private var cachedReadySignature: String?

    init(
        modelRoot: URL,
        privateStorageRoot: URL? = nil,
        manifest: QwenSnapshotManifest = Qwen3TTSProvenance.publicSnapshot,
        downloader: any QwenSnapshotDownloading = HuggingFaceQwenSnapshotDownloader(),
        freeSpaceReader: any QwenFreeSpaceReading = FoundationQwenFreeSpaceReader(),
        fileManager: FileManager = .default,
        minimumFreeBytes: Int64 = Qwen3TTSProvenance.minimumFreeByteCount,
        postReplacementValidation: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }
    ) {
        self.modelRoot = modelRoot.standardizedFileURL
        self.privateStorageRoot = (privateStorageRoot ?? modelRoot).standardizedFileURL
        self.manifest = manifest
        snapshotByteCount = manifest.byteCount
        self.downloader = downloader
        self.freeSpaceReader = freeSpaceReader
        self.fileManager = fileManager
        self.minimumFreeBytes = minimumFreeBytes
        self.postReplacementValidation = postReplacementValidation
    }

    /// Read-only inspection. A process-local metadata signature avoids hashing
    /// the 1.838-GiB snapshot on every Turn, while `prepare` always performs a
    /// full load-time hash gate.
    func readiness() -> QwenModelStoreReadiness {
        if let latestProgress, activePreparationID != nil {
            return .preparing(latestProgress)
        }
        guard fileManager.fileExists(atPath: snapshotDirectory.path) else {
            return .notInstalled
        }

        do {
            try validateConfiguredRoots()
            let quickSignature = try snapshotMetadataSignature(at: snapshotDirectory)
            if quickSignature != cachedReadySignature {
                try validateReadySnapshot(at: snapshotDirectory, hashesRequired: true)
                cachedReadySignature = quickSignature
            }
            return .ready(modelDirectory: snapshotDirectory)
        } catch let failure as QwenModelStoreFailure {
            return .unavailable(failure)
        } catch {
            return .unavailable(.storageFailure)
        }
    }

    /// For a new installation, the provider loader runs against verified
    /// sibling staging and must produce a valid derived tokenizer receipt before
    /// promotion. Existing ready revisions get full hashes before and after load.
    func prepare<LoadedModel: Sendable>(
        allowDownload: Bool,
        validateStagedLoad: @escaping @Sendable (URL) async throws -> Void,
        loadPromoted: @escaping @Sendable (URL) async throws -> LoadedModel,
        progress: @escaping @Sendable (QwenModelStoreProgress) -> Void
    ) async throws -> (modelDirectory: URL, loadedModel: LoadedModel) {
        switch readiness() {
        case .ready(let modelDirectory):
            try Task.checkCancellation()
            try validateReadySnapshot(at: modelDirectory, hashesRequired: true)
            try Task.checkCancellation()
            let loadedModel = try await loadSafely(from: modelDirectory, using: loadPromoted)
            try Task.checkCancellation()
            try validateReadySnapshot(at: modelDirectory, hashesRequired: true)
            try Task.checkCancellation()
            cachedReadySignature = try snapshotMetadataSignature(at: modelDirectory)
            return (modelDirectory, loadedModel)
        case .preparing:
            throw QwenModelStoreFailure.preparationInProgress
        case .notInstalled, .unavailable:
            guard allowDownload else {
                throw QwenModelStoreFailure.missingFile
            }
        }

        try Task.checkCancellation()
        try validateConfiguredRoots()
        let availableBytes = try freeSpaceReader.availableBytes(for: revisionRoot)
        guard availableBytes >= minimumFreeBytes else {
            throw QwenModelStoreFailure.insufficientFreeSpace
        }

        let preparationID = UUID()
        activePreparationID = preparationID
        publishProgress(.checkingStorage, completedBytes: 0, to: progress)
        let staging = stagingRoot.appendingPathComponent(
            preparationID.uuidString.lowercased(),
            isDirectory: true
        )
        var promotion: SnapshotPromotion?

        do {
            try createPrivateStorageHierarchy()
            try removeAbandonedStaging(except: staging)
            try createPrivateDirectory(staging)
            publishProgress(.downloading, completedBytes: 0, to: progress)

            let relay: @Sendable (QwenModelStoreProgress) -> Void = { [weak self] update in
                Task { await self?.recordDownloadProgress(update, preparationID: preparationID) }
                progress(update)
            }
            try await downloader.downloadSnapshot(
                manifest: manifest,
                destination: staging,
                cacheRoot: cacheRoot,
                progress: relay
            )
            try Task.checkCancellation()

            publishProgress(.verifying, completedBytes: manifest.byteCount, to: progress)
            try validatePublicSnapshot(
                at: staging,
                hashesRequired: true,
                permittedRuntimeFiles: []
            )
            try applyPrivatePermissionsRecursively(at: staging)
            try writeVerificationReceipt(to: staging)

            // Upstream may mutate tokenizer.json and has a corruption branch
            // that can remove its model directory. It therefore never receives
            // the promoted directory during first installation.
            try await loadSafely(from: staging, using: validateStagedLoad)
            try Task.checkCancellation()
            try recordDerivedTokenizer(at: staging)
            try validateReadySnapshot(at: staging, hashesRequired: true)
            try Task.checkCancellation()

            publishProgress(.promoting, completedBytes: manifest.byteCount, to: progress)
            try promote(staging: staging, promotion: &promotion)
            // Reload from the promoted path. Even though the audited upstream
            // implementation eagerly reads weights/tokenizers today, this
            // avoids retaining a future lazy reference to the renamed staging
            // directory.
            try Task.checkCancellation()
            try validateReadySnapshot(at: snapshotDirectory, hashesRequired: true)
            let loadedModel = try await loadSafely(
                from: snapshotDirectory,
                using: loadPromoted
            )
            try Task.checkCancellation()
            try validateReadySnapshot(at: snapshotDirectory, hashesRequired: true)
            try Task.checkCancellation()
            let readySignature = try snapshotMetadataSignature(at: snapshotDirectory)
            try Task.checkCancellation()
            try commit(promotion)
            cachedReadySignature = readySignature
            activePreparationID = nil
            latestProgress = nil
            return (snapshotDirectory, loadedModel)
        } catch {
            let originalError = error
            do {
                try rollback(promotion)
                if fileManager.fileExists(atPath: staging.path) {
                    try removeScopedItem(staging, inside: stagingRoot)
                }
            } catch {
                cachedReadySignature = nil
                clearPreparation()
                throw QwenModelStoreFailure.storageFailure
            }
            cachedReadySignature = nil
            clearPreparation()
            throw preparationFailure(for: originalError)
        }
    }

    func removeInstalledRevision() throws {
        guard activePreparationID == nil else {
            throw QwenModelStoreFailure.preparationInProgress
        }
        try validateConfiguredRoots()
        if fileManager.fileExists(atPath: revisionRoot.path) {
            try validateExistingDirectory(revisionRoot)
            try removeScopedItem(revisionRoot, inside: repositoryRoot)
        }
        cachedReadySignature = nil
        latestProgress = nil
    }

    private var repositoryRoot: URL {
        modelRoot.appendingPathComponent(safeRepositoryDirectoryName, isDirectory: true)
    }

    private var revisionRoot: URL {
        repositoryRoot.appendingPathComponent(manifest.revision, isDirectory: true)
    }

    private var snapshotDirectory: URL {
        revisionRoot.appendingPathComponent("snapshot", isDirectory: true)
    }

    private var stagingRoot: URL {
        revisionRoot.appendingPathComponent("staging", isDirectory: true)
    }

    private var cacheRoot: URL {
        revisionRoot.appendingPathComponent("hub-cache", isDirectory: true)
    }

    private var safeRepositoryDirectoryName: String {
        manifest.repositoryID.replacingOccurrences(of: "/", with: "--")
    }

    private func loadSafely<LoadedModel: Sendable>(
        from directory: URL,
        using loader: @escaping @Sendable (URL) async throws -> LoadedModel
    ) async throws -> LoadedModel {
        do {
            return try await loader(directory)
        } catch is CancellationError {
            throw QwenModelStoreFailure.cancelled
        } catch let failure as QwenModelStoreFailure {
            throw failure
        } catch {
            throw QwenModelStoreFailure.loaderValidationFailed
        }
    }

    private func publishProgress(
        _ stage: QwenModelStoreProgress.Stage,
        completedBytes: Int64,
        to callback: @escaping @Sendable (QwenModelStoreProgress) -> Void
    ) {
        let value = QwenModelStoreProgress(
            stage: stage,
            completedBytes: min(max(completedBytes, 0), manifest.byteCount),
            totalBytes: manifest.byteCount
        )
        latestProgress = value
        callback(value)
    }

    private func recordDownloadProgress(
        _ update: QwenModelStoreProgress,
        preparationID: UUID
    ) {
        guard activePreparationID == preparationID else { return }
        latestProgress = QwenModelStoreProgress(
            stage: .downloading,
            completedBytes: min(max(update.completedBytes, 0), manifest.byteCount),
            totalBytes: manifest.byteCount
        )
    }

    private func clearPreparation() {
        activePreparationID = nil
        latestProgress = nil
    }

    private func validateConfiguredRoots() throws {
        guard isSafeIdentity(manifest.repositoryID, allowsSlash: true),
              isSafeIdentity(manifest.revision, allowsSlash: false),
              manifest.revision.count == 40,
              manifest.revision.allSatisfy(\.isHexDigit),
              manifest.files.count == Set(manifest.files.map(\.path)).count,
              !manifest.files.isEmpty,
              manifest.files.allSatisfy({ file in
                  isSafeRelativePath(file.path)
                      && file.byteCount > 0
                      && file.sha256.count == 64
                      && file.sha256.allSatisfy(\.isHexDigit)
              }),
              manifest.byteCount > 0 else {
            throw QwenModelStoreFailure.invalidStorageRoot
        }

        guard modelRoot.isFileURL,
              privateStorageRoot.isFileURL,
              modelRoot.path != "/",
              privateStorageRoot.path != "/",
              modelRoot == privateStorageRoot
                  || isStrictDescendant(modelRoot, of: privateStorageRoot),
              isStrictDescendant(repositoryRoot, of: modelRoot),
              isStrictDescendant(revisionRoot, of: repositoryRoot),
              isStrictDescendant(snapshotDirectory, of: revisionRoot),
              isStrictDescendant(stagingRoot, of: revisionRoot),
              isStrictDescendant(cacheRoot, of: revisionRoot) else {
            throw QwenModelStoreFailure.invalidStorageRoot
        }
        try validateExistingPrivatePathComponents()
    }

    private func validateExistingPrivatePathComponents() throws {
        for path in privateDirectoryChain() where fileManager.fileExists(atPath: path.path) {
            try validateExistingDirectory(path)
        }
    }

    private func validateExistingDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw QwenModelStoreFailure.symbolicLinkRejected
        }
        guard values.isDirectory == true else {
            throw QwenModelStoreFailure.invalidStorageRoot
        }
    }

    private func privateDirectoryChain() -> [URL] {
        var result = pathChain(from: privateStorageRoot, through: modelRoot)
        result.append(contentsOf: [repositoryRoot, revisionRoot, stagingRoot, cacheRoot])
        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func pathChain(from root: URL, through target: URL) -> [URL] {
        guard root != target else { return [root] }
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard targetComponents.starts(with: rootComponents) else { return [] }
        var chain = [root]
        var current = root
        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            chain.append(current)
        }
        return chain
    }

    private func createPrivateStorageHierarchy() throws {
        for directory in privateDirectoryChain() {
            try createPrivateDirectory(directory)
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        do {
            if fileManager.fileExists(atPath: url.path) {
                try validateExistingDirectory(url)
            } else {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch let failure as QwenModelStoreFailure {
            throw failure
        } catch {
            throw QwenModelStoreFailure.storageFailure
        }
    }

    private func validateReadySnapshot(at root: URL, hashesRequired: Bool) throws {
        try validateVerificationReceipt(at: root)
        let tokenizer = root.appendingPathComponent(Self.derivedTokenizerName)
        let derivedReceipt = root.appendingPathComponent(Self.derivedReceiptName)
        guard fileManager.fileExists(atPath: tokenizer.path),
              fileManager.fileExists(atPath: derivedReceipt.path) else {
            throw QwenModelStoreFailure.derivedTokenizerInvalid
        }
        try validateDerivedReceipt(tokenizerURL: tokenizer, receiptURL: derivedReceipt)
        try validatePublicSnapshot(
            at: root,
            hashesRequired: hashesRequired,
            permittedRuntimeFiles: Set([
                Self.verificationReceiptName,
                Self.derivedTokenizerName,
                Self.derivedReceiptName,
            ])
        )
    }

    private func validateVerificationReceipt(at root: URL) throws {
        let url = root.appendingPathComponent(Self.verificationReceiptName)
        let receipt: VerificationReceipt
        do {
            receipt = try JSONDecoder().decode(
                VerificationReceipt.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw QwenModelStoreFailure.invalidVerificationReceipt
        }
        guard receipt.schemaVersion == 1,
              receipt.repositoryID == manifest.repositoryID,
              receipt.revision == manifest.revision,
              receipt.fileCount == manifest.files.count,
              receipt.byteCount == manifest.byteCount,
              receipt.manifestFingerprint == manifest.fingerprint else {
            throw QwenModelStoreFailure.invalidVerificationReceipt
        }
    }

    private func recordDerivedTokenizer(at root: URL) throws {
        try validateVerificationReceipt(at: root)
        try validatePublicSnapshot(
            at: root,
            hashesRequired: true,
            permittedRuntimeFiles: Set([
                Self.verificationReceiptName,
                Self.derivedTokenizerName,
            ])
        )
        let tokenizer = root.appendingPathComponent(Self.derivedTokenizerName)
        let metadata = try regularFileMetadata(tokenizer)
        guard metadata.byteCount > 0 else {
            throw QwenModelStoreFailure.derivedTokenizerInvalid
        }
        let data = try Data(contentsOf: tokenizer)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["model"] != nil else {
            throw QwenModelStoreFailure.derivedTokenizerInvalid
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenizer.path)
        try writePrivateJSON(
            DerivedRuntimeReceipt(
                schemaVersion: 1,
                artifact: Self.derivedTokenizerName,
                derivation: "Qwen3TTSModel.fromModelDirectory",
                byteCount: metadata.byteCount,
                sha256: try QwenSHA256.file(tokenizer)
            ),
            to: root.appendingPathComponent(Self.derivedReceiptName)
        )
    }

    private func validateDerivedReceipt(tokenizerURL: URL, receiptURL: URL) throws {
        let receipt: DerivedRuntimeReceipt
        do {
            receipt = try JSONDecoder().decode(
                DerivedRuntimeReceipt.self,
                from: Data(contentsOf: receiptURL)
            )
        } catch {
            throw QwenModelStoreFailure.derivedTokenizerInvalid
        }
        let metadata = try regularFileMetadata(tokenizerURL)
        guard receipt.schemaVersion == 1,
              receipt.artifact == Self.derivedTokenizerName,
              receipt.derivation == "Qwen3TTSModel.fromModelDirectory",
              receipt.byteCount == metadata.byteCount,
              receipt.sha256 == (try QwenSHA256.file(tokenizerURL)) else {
            throw QwenModelStoreFailure.derivedTokenizerInvalid
        }
    }

    private func validatePublicSnapshot(
        at root: URL,
        hashesRequired: Bool,
        permittedRuntimeFiles: Set<String>
    ) throws {
        try validateSnapshotRoot(root)
        let inventory = try inventory(at: root)
        let publicPaths = Set(manifest.files.map(\.path))
        let expectedFiles = publicPaths.union(permittedRuntimeFiles)
        guard inventory.files == expectedFiles else {
            if !publicPaths.subtracting(inventory.files).isEmpty {
                throw QwenModelStoreFailure.missingFile
            }
            throw QwenModelStoreFailure.unexpectedSnapshotShape
        }
        let expectedDirectories = Set(manifest.files.flatMap { parentDirectories(for: $0.path) })
        guard inventory.directories == expectedDirectories else {
            throw QwenModelStoreFailure.unexpectedSnapshotShape
        }

        for expected in manifest.files {
            let fileURL = root.appendingPathComponent(expected.path)
            let metadata = try regularFileMetadata(fileURL)
            guard metadata.byteCount == expected.byteCount else {
                throw QwenModelStoreFailure.wrongFileSize
            }
            if hashesRequired,
               try QwenSHA256.file(fileURL) != expected.sha256 {
                throw QwenModelStoreFailure.hashMismatch
            }
        }
    }

    private func validateSnapshotRoot(_ root: URL) throws {
        let standardized = root.standardizedFileURL
        guard isStrictDescendant(standardized, of: revisionRoot) else {
            throw QwenModelStoreFailure.invalidSnapshotRoot
        }
        for component in pathChain(from: revisionRoot, through: standardized) {
            guard fileManager.fileExists(atPath: component.path) else {
                throw QwenModelStoreFailure.invalidSnapshotRoot
            }
            try validateExistingDirectory(component)
        }
    }

    private func inventory(at root: URL) throws -> SnapshotInventory {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw QwenModelStoreFailure.unexpectedSnapshotShape
        }

        var files = Set<String>()
        var directories = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            let relative = try relativePath(for: url, under: root)
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw QwenModelStoreFailure.symbolicLinkRejected
            }
            if values.isDirectory == true {
                directories.insert(relative)
            } else if values.isRegularFile == true {
                files.insert(relative)
            } else {
                throw QwenModelStoreFailure.unexpectedSnapshotShape
            }
        }
        return SnapshotInventory(files: files, directories: directories)
    }

    private func regularFileMetadata(_ url: URL) throws -> (byteCount: Int64, modified: Date) {
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
        )
        guard values.isSymbolicLink != true else {
            throw QwenModelStoreFailure.symbolicLinkRejected
        }
        guard values.isRegularFile == true else {
            throw QwenModelStoreFailure.missingFile
        }
        guard let size = values.fileSize, let modified = values.contentModificationDate else {
            throw QwenModelStoreFailure.storageFailure
        }
        return (Int64(size), modified)
    }

    private func snapshotMetadataSignature(at root: URL) throws -> String {
        let paths = try inventory(at: root).files.sorted()
        let rows = try paths.map { path -> String in
            let metadata = try regularFileMetadata(root.appendingPathComponent(path))
            return "\(path)\u{0}\(metadata.byteCount)\u{0}\(metadata.modified.timeIntervalSince1970)"
        }
        return QwenSHA256.string(Data(rows.joined(separator: "\n").utf8))
    }

    private struct SnapshotPromotion {
        let backup: URL?
    }

    private func promote(
        staging: URL,
        promotion: inout SnapshotPromotion?
    ) throws {
        let final = snapshotDirectory
        do {
            if fileManager.fileExists(atPath: final.path) {
                try validateExistingDirectory(final)
                let backupName = "snapshot-backup-\(UUID().uuidString.lowercased())"
                let backup = revisionRoot.appendingPathComponent(
                    backupName,
                    isDirectory: true
                )
                guard isStrictDescendant(backup, of: revisionRoot) else {
                    throw QwenModelStoreFailure.invalidStorageRoot
                }
                _ = try fileManager.replaceItemAt(
                    final,
                    withItemAt: staging,
                    backupItemName: backupName,
                    options: [.withoutDeletingBackupItem]
                )
                // Publish the rollback receipt immediately after the atomic
                // replacement. Any later postcondition failure must be able to
                // restore the prior verified snapshot from the retained backup.
                promotion = SnapshotPromotion(backup: backup)
                try postReplacementValidation(final, backup)
                guard fileManager.fileExists(atPath: backup.path) else {
                    throw QwenModelStoreFailure.storageFailure
                }
                try validateExistingDirectory(backup)
            } else {
                try fileManager.moveItem(at: staging, to: final)
                promotion = SnapshotPromotion(backup: nil)
            }
        } catch let failure as QwenModelStoreFailure {
            throw failure
        } catch {
            throw QwenModelStoreFailure.storageFailure
        }
    }

    /// The previous snapshot remains available until every post-promotion hash,
    /// loader, and cancellation gate has succeeded. Committing is therefore
    /// only the scoped removal of that retained backup.
    private func commit(_ promotion: SnapshotPromotion?) throws {
        guard let promotion else {
            throw QwenModelStoreFailure.storageFailure
        }
        guard let backup = promotion.backup else { return }
        guard fileManager.fileExists(atPath: backup.path) else {
            throw QwenModelStoreFailure.storageFailure
        }
        try validateExistingDirectory(backup)
        try removeScopedItem(backup, inside: revisionRoot)
    }

    /// Restores the exact prior directory on replacement failure. A failed
    /// first installation has no backup, so its promoted candidate is removed.
    private func rollback(_ promotion: SnapshotPromotion?) throws {
        guard let promotion else { return }
        let final = snapshotDirectory
        guard let backup = promotion.backup else {
            if fileManager.fileExists(atPath: final.path) {
                try removeScopedItem(final, inside: revisionRoot)
            }
            return
        }

        try validateExistingDirectory(backup)
        if fileManager.fileExists(atPath: final.path) {
            let failedName = "snapshot-rejected-\(UUID().uuidString.lowercased())"
            let failed = revisionRoot.appendingPathComponent(
                failedName,
                isDirectory: true
            )
            guard isStrictDescendant(failed, of: revisionRoot) else {
                throw QwenModelStoreFailure.invalidStorageRoot
            }
            _ = try fileManager.replaceItemAt(
                final,
                withItemAt: backup,
                backupItemName: failedName,
                options: [.withoutDeletingBackupItem]
            )
            if fileManager.fileExists(atPath: failed.path) {
                try removeScopedItem(failed, inside: revisionRoot)
            }
        } else {
            try fileManager.moveItem(at: backup, to: final)
        }
        try validateExistingDirectory(final)
    }

    private func preparationFailure(for error: Error) -> QwenModelStoreFailure {
        if error is CancellationError {
            return .cancelled
        }
        if let failure = error as? QwenModelStoreFailure {
            return failure
        }
        return .downloadFailed
    }

    private func writeVerificationReceipt(to root: URL) throws {
        try writePrivateJSON(
            VerificationReceipt(
                schemaVersion: 1,
                repositoryID: manifest.repositoryID,
                revision: manifest.revision,
                fileCount: manifest.files.count,
                byteCount: manifest.byteCount,
                manifestFingerprint: manifest.fingerprint
            ),
            to: root.appendingPathComponent(Self.verificationReceiptName)
        )
    }

    private func writePrivateJSON<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try JSONEncoder.publicSafe.encode(value).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw QwenModelStoreFailure.storageFailure
        }
    }

    private func applyPrivatePermissionsRecursively(at root: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            throw QwenModelStoreFailure.storageFailure
        }
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw QwenModelStoreFailure.symbolicLinkRejected
            }
            try fileManager.setAttributes(
                [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private func removeAbandonedStaging(except current: URL) throws {
        let children = try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        )
        for child in children where child.standardizedFileURL != current.standardizedFileURL {
            try removeScopedItem(child, inside: stagingRoot)
        }
    }

    private func removeScopedItem(_ item: URL, inside parent: URL) throws {
        try validateExistingDirectory(parent)
        guard isStrictDescendant(item.standardizedFileURL, of: parent.standardizedFileURL),
              item.standardizedFileURL.path != "/" else {
            throw QwenModelStoreFailure.invalidStorageRoot
        }
        try fileManager.removeItem(at: item)
    }

    private func relativePath(for url: URL, under root: URL) throws -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else {
            throw QwenModelStoreFailure.invalidSnapshotRoot
        }
        let relative = String(path.dropFirst(prefix.count))
        guard isSafeRelativePath(relative) else {
            throw QwenModelStoreFailure.unexpectedSnapshotShape
        }
        return relative
    }

    private func parentDirectories(for path: String) -> [String] {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return [] }
        return (1 ..< components.count).map { components.prefix($0).joined(separator: "/") }
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

    private func isSafeIdentity(_ value: String, allowsSlash: Bool) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            return false
        }
        if !allowsSlash, value.contains("/") { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func isStrictDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }
}

private struct SnapshotInventory {
    let files: Set<String>
    let directories: Set<String>
}

private struct VerificationReceipt: Codable {
    let schemaVersion: Int
    let repositoryID: String
    let revision: String
    let fileCount: Int
    let byteCount: Int64
    let manifestFingerprint: String
}

private struct DerivedRuntimeReceipt: Codable {
    let schemaVersion: Int
    let artifact: String
    let derivation: String
    let byteCount: Int64
    let sha256: String
}

enum QwenSHA256 {
    static func string(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func file(_ url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw QwenModelStoreFailure.storageFailure
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while true {
                let data = try autoreleasepool {
                    try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                }
                guard !data.isEmpty else { break }
                hasher.update(data: data)
            }
        } catch {
            throw QwenModelStoreFailure.storageFailure
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var publicSafe: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
