import Foundation
import XCTest

@testable import InterviewArcLiveLocalSpeechAdapter

@MainActor
final class LocalSpeechModelStoreTests: XCTestCase {
    func testNonDerivingModelUsesVerifiedSnapshotWithoutQwenTokenizer() async throws {
        let fixture = try Fixture.make(derivesTokenizer: false)
        defer { fixture.remove() }
        let result = try await fixture.store.prepare(allowDownload: true,
            validateStagedLoad: { _ in }, loadPromoted: { $0 }, progress: { _ in })
        XCTAssertFalse(fixture.fileManager.fileExists(atPath:
            result.modelDirectory.appendingPathComponent("tokenizer.json").path))
        let readiness = await fixture.store.readiness()
        XCTAssertEqual(readiness, .ready(modelDirectory: result.modelDirectory))
        let weight = result.modelDirectory.appendingPathComponent("speech_tokenizer/model.safetensors")
        try Data([9, 9, 9, 9]).write(to: weight)
        let corrupted = await fixture.store.readiness()
        XCTAssertEqual(corrupted, .unavailable(.hashMismatch))
    }

    func testPinnedPublicProvenanceIsCompleteAndImmutable() {
        let snapshot = Qwen3TTSProvenance.publicSnapshot

        XCTAssertEqual(Qwen3TTSProvenance.packageVersion, "0.1.3")
        XCTAssertEqual(
            Qwen3TTSProvenance.packageRevision,
            "a228dc056c6b298a2f5aff7f10e3aed537577fa0"
        )
        XCTAssertEqual(
            Qwen3TTSProvenance.packageUpstreamRevision,
            "d302a5c6080d2bb97bae38c7418f82abb76013b6"
        )
        XCTAssertEqual(
            snapshot.revision,
            "049ef77fe8816b536193c0c25f9a214d17921282"
        )
        XCTAssertEqual(snapshot.files.count, 14)
        XCTAssertEqual(snapshot.byteCount, 1_973_575_388)
        XCTAssertEqual(snapshot.byteCount, Qwen3TTSProvenance.snapshotByteCount)
        XCTAssertEqual(Qwen3TTSProvenance.minimumFreeByteCount, 4_294_967_296)
        XCTAssertEqual(Set(snapshot.files.map(\.path)), Set([
            ".gitattributes",
            "README.md",
            "config.json",
            "generation_config.json",
            "merges.txt",
            "model.safetensors",
            "model.safetensors.index.json",
            "preprocessor_config.json",
            "speech_tokenizer/config.json",
            "speech_tokenizer/configuration.json",
            "speech_tokenizer/model.safetensors",
            "speech_tokenizer/preprocessor_config.json",
            "tokenizer_config.json",
            "vocab.json",
        ]))

        let mainWeights = snapshot.files.first { $0.path == "model.safetensors" }
        XCTAssertEqual(mainWeights?.byteCount, 1_286_743_170)
        XCTAssertEqual(
            mainWeights?.sha256,
            "3bcb2c4a127e6243e81a30b7126c7865f686d3559de4f938e5d3b150c6a9560d"
        )
        let tokenizerWeights = snapshot.files.first {
            $0.path == "speech_tokenizer/model.safetensors"
        }
        XCTAssertEqual(tokenizerWeights?.byteCount, 682_293_092)
        XCTAssertEqual(
            tokenizerWeights?.sha256,
            "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"
        )
        XCTAssertEqual(snapshot.fingerprint.count, 64)
    }

    func testReadinessAndNeverDownloadHaveNoFilesystemOrNetworkSideEffect() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let before = fixture.fileManager.fileExists(atPath: fixture.modelRoot.path)
        let readiness = await fixture.store.readiness()

        XCTAssertEqual(readiness, .notInstalled)
        XCTAssertEqual(before, false)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.modelRoot.path))
        let initialDownloadCount = await fixture.downloader.callCount()
        XCTAssertEqual(initialDownloadCount, 0)

        do {
            _ = try await fixture.prepare(allowDownload: false)
            XCTFail("neverDownload must not install a snapshot")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .missingFile)
        }
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.modelRoot.path))
        let finalDownloadCount = await fixture.downloader.callCount()
        XCTAssertEqual(finalDownloadCount, 0)
    }

    func testAuthorizedDownloadVerifiesPromotesAndReportsBoundedProgress() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let progress = ProgressRecorder()

        let directory = try await fixture.prepare(allowDownload: true) { update in
            progress.append(update)
        }

        let downloadCount = await fixture.downloader.callCount()
        let downloadedRevisions = await fixture.downloader.revisions()
        let readiness = await fixture.store.readiness()
        XCTAssertEqual(downloadCount, 1)
        XCTAssertEqual(downloadedRevisions, [fixture.manifest.revision])
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: directory.path))
        XCTAssertEqual(readiness, .ready(modelDirectory: directory))
        XCTAssertEqual(progress.values.last?.completedBytes, fixture.manifest.byteCount)
        XCTAssertTrue(progress.values.allSatisfy {
            $0.totalBytes == fixture.manifest.byteCount
                && $0.completedBytes >= 0
                && $0.completedBytes <= $0.totalBytes
        })

        let receipt = directory.appendingPathComponent(LocalSpeechModelStore.verificationReceiptName)
        let receiptText = try String(contentsOf: receipt, encoding: .utf8)
        let directoryPermissions = try permissions(directory)
        let configPermissions = try permissions(
            directory.appendingPathComponent("config.json")
        )
        XCTAssertTrue(receiptText.contains(fixture.manifest.revision))
        XCTAssertFalse(receiptText.contains(fixture.temporaryRoot.path))
        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertEqual(configPermissions, 0o600)
    }

    func testInsufficientFreeSpaceFailsBeforeCreatingStorageOrDownloading() async throws {
        let fixture = try Fixture.make(availableBytes: 99, minimumFreeBytes: 100)
        defer { fixture.remove() }

        do {
            _ = try await fixture.prepare(allowDownload: true)
            XCTFail("download should require the configured free-space floor")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .insufficientFreeSpace)
        }

        let downloadCount = await fixture.downloader.callCount()
        XCTAssertEqual(downloadCount, 0)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.modelRoot.path))
    }

    func testMalformedManifestFailsBeforeStorageOrNetworkMutation() async throws {
        let validHash = String(repeating: "a", count: 64)
        let malformedFileSets: [[LocalSpeechSnapshotFile]] = [
            [.init(path: "../escape", byteCount: 1, sha256: validHash)],
            [.init(path: "config.json", byteCount: 0, sha256: validHash)],
            [.init(path: "config.json", byteCount: 1, sha256: "too-short")],
            [
                .init(path: "config.json", byteCount: 1, sha256: validHash),
                .init(path: "config.json", byteCount: 1, sha256: validHash),
            ],
        ]

        for files in malformedFileSets {
            let fixture = try Fixture.make(manifestFiles: files)
            defer { fixture.remove() }

            do {
                _ = try await fixture.prepare(allowDownload: true)
                XCTFail("a malformed immutable manifest must fail closed")
            } catch let failure as LocalSpeechModelStoreFailure {
                XCTAssertEqual(failure, .invalidStorageRoot)
            }

            let downloadCount = await fixture.downloader.callCount()
            XCTAssertEqual(downloadCount, 0)
            XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.modelRoot.path))
        }
    }

    func testInvalidSnapshotMatrixNeverPromotes() async throws {
        let cases: [(FixtureDownloader.Behavior, LocalSpeechModelStoreFailure)] = [
            (.missingFile, .missingFile),
            (.extraFile, .unexpectedSnapshotShape),
            (.zeroFile, .wrongFileSize),
            (.truncatedFile, .wrongFileSize),
            (.wrongHash, .hashMismatch),
            (.symbolicLinkFile, .symbolicLinkRejected),
            (.symbolicLinkRoot, .symbolicLinkRejected),
        ]

        for (behavior, expected) in cases {
            let fixture = try Fixture.make(behaviors: [behavior])
            defer { fixture.remove() }

            do {
                _ = try await fixture.prepare(allowDownload: true)
                XCTFail("\(behavior) must not promote")
            } catch let failure as LocalSpeechModelStoreFailure {
                XCTAssertEqual(failure, expected, "behavior: \(behavior)")
            }

            let snapshots = try fixture.findDirectories(named: "snapshot")
            XCTAssertTrue(snapshots.isEmpty, "behavior promoted: \(behavior)")
        }
    }

    func testCancellationRemovesOnlyCurrentStagingAndDoesNotPromote() async throws {
        let fixture = try Fixture.make(behaviors: [.waitForCancellation])
        defer { fixture.remove() }

        let task = Task {
            try await fixture.prepare(allowDownload: true)
        }
        await fixture.downloader.waitUntilCalled()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled transfer must fail")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .cancelled)
        }

        let readiness = await fixture.store.readiness()
        XCTAssertEqual(readiness, .notInstalled)
        let snapshots = try fixture.findDirectories(named: "snapshot")
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testFailedReplacementLeavesExistingSnapshotBytesUntouched() async throws {
        let fixture = try Fixture.make(behaviors: [.valid, .downloadFailure])
        defer { fixture.remove() }

        let directory = try await fixture.prepare(allowDownload: true)
        let config = directory.appendingPathComponent("config.json")
        let original = try Data(contentsOf: config)

        // Removing the receipt makes the existing tree ineligible for loading,
        // forcing a new staged transfer while retaining the old bytes.
        try fixture.fileManager.removeItem(
            at: directory.appendingPathComponent(LocalSpeechModelStore.verificationReceiptName)
        )
        do {
            _ = try await fixture.prepare(allowDownload: true)
            XCTFail("scripted replacement must fail")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .downloadFailed)
        }

        let retainedConfig = try Data(contentsOf: config)
        XCTAssertEqual(retainedConfig, original)
        XCTAssertTrue(fixture.fileManager.fileExists(atPath: directory.path))
    }

    func testPostPromotionLoaderFailureRestoresPriorReadySnapshot() async throws {
        let fixture = try Fixture.make(behaviors: [.valid, .valid])
        defer { fixture.remove() }
        let directory = try await fixture.prepare(allowDownload: true)
        let initialReadiness = await fixture.store.readiness()
        XCTAssertEqual(initialReadiness, .ready(modelDirectory: directory))
        let originalConfig = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        let repair = try fixture.invalidateVerificationReceipt(in: directory)

        do {
            _ = try await fixture.store.prepare(
                allowDownload: true,
                validateStagedLoad: { staging in
                    try await FixtureModelLoader.validateStaged(from: staging)
                    try repair.restore()
                },
                loadPromoted: { _ in throw FixtureLoaderFailure.failed },
                progress: { _ in }
            )
            XCTFail("a promoted loader failure must roll back")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .loaderValidationFailed)
        }

        let restoredReadiness = await fixture.store.readiness()
        let restoredConfig = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        XCTAssertEqual(restoredReadiness, .ready(modelDirectory: directory))
        XCTAssertEqual(restoredConfig, originalConfig)
    }

    func testPostReplacementValidationFailureRestoresPriorReadySnapshot() async throws {
        let postReplacementGate = FailFirstPostReplacementValidation()
        let fixture = try Fixture.make(
            behaviors: [.valid, .valid],
            postReplacementValidation: { final, backup in
                try postReplacementGate.validate(final: final, backup: backup)
            }
        )
        defer { fixture.remove() }
        let directory = try await fixture.prepare(allowDownload: true)
        let originalConfig = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        let repair = try fixture.invalidateVerificationReceipt(in: directory)

        do {
            _ = try await fixture.store.prepare(
                allowDownload: true,
                validateStagedLoad: { staging in
                    try await FixtureModelLoader.validateStaged(from: staging)
                    try repair.restore()
                },
                loadPromoted: { promoted in
                    try await FixtureModelLoader.loadPromoted(from: promoted)
                },
                progress: { _ in }
            )
            XCTFail("a post-replacement validation failure must roll back")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .storageFailure)
        }

        let restoredReadiness = await fixture.store.readiness()
        let restoredConfig = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        let revisionChildren = try fixture.fileManager.contentsOfDirectory(
            at: directory.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(postReplacementGate.didFailAfterSeeingBothDirectories())
        XCTAssertEqual(restoredReadiness, .ready(modelDirectory: directory))
        XCTAssertEqual(restoredConfig, originalConfig)
        XCTAssertFalse(revisionChildren.contains {
            $0.lastPathComponent.hasPrefix("snapshot-backup-")
                || $0.lastPathComponent.hasPrefix("snapshot-rejected-")
        })
    }

    func testPostPromotionHashFailureRestoresPriorReadySnapshot() async throws {
        let fixture = try Fixture.make(behaviors: [.valid, .valid])
        defer { fixture.remove() }
        let directory = try await fixture.prepare(allowDownload: true)
        let initialReadiness = await fixture.store.readiness()
        XCTAssertEqual(initialReadiness, .ready(modelDirectory: directory))
        let originalConfig = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        let repair = try fixture.invalidateVerificationReceipt(in: directory)

        do {
            _ = try await fixture.store.prepare(
                allowDownload: true,
                validateStagedLoad: { staging in
                    try await FixtureModelLoader.validateStaged(from: staging)
                    try repair.restore()
                },
                loadPromoted: { promoted in
                    let config = promoted.appendingPathComponent("config.json")
                    let bytes = try Data(contentsOf: config)
                    try Data(repeating: 0x58, count: bytes.count).write(to: config)
                    return FixtureLoadedModel()
                },
                progress: { _ in }
            )
            XCTFail("post-load hash corruption must roll back")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .hashMismatch)
        }

        let restoredReadiness = await fixture.store.readiness()
        let restoredConfig = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        XCTAssertEqual(restoredReadiness, .ready(modelDirectory: directory))
        XCTAssertEqual(restoredConfig, originalConfig)
    }

    func testPostPromotionCancellationRestoresPriorReadySnapshot() async throws {
        let fixture = try Fixture.make(behaviors: [.valid, .valid])
        defer { fixture.remove() }
        let directory = try await fixture.prepare(allowDownload: true)
        let initialReadiness = await fixture.store.readiness()
        XCTAssertEqual(initialReadiness, .ready(modelDirectory: directory))
        let repair = try fixture.invalidateVerificationReceipt(in: directory)
        let gate = NoncancellableLoaderGate()

        let task = Task {
            try await fixture.store.prepare(
                allowDownload: true,
                validateStagedLoad: { staging in
                    try await FixtureModelLoader.validateStaged(from: staging)
                    try repair.restore()
                },
                loadPromoted: { _ in
                    await gate.wait()
                    return FixtureLoadedModel()
                },
                progress: { _ in }
            )
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("cancellation after promotion must roll back")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .cancelled)
        }

        let restoredReadiness = await fixture.store.readiness()
        XCTAssertEqual(restoredReadiness, .ready(modelDirectory: directory))
    }

    func testSuccessfulReplacementRemovesBackupOnlyAfterFinalGates() async throws {
        let fixture = try Fixture.make(behaviors: [.valid, .valid])
        defer { fixture.remove() }
        let directory = try await fixture.prepare(allowDownload: true)
        let repair = try fixture.invalidateVerificationReceipt(in: directory)

        let prepared = try await fixture.store.prepare(
            allowDownload: true,
            validateStagedLoad: { staging in
                try await FixtureModelLoader.validateStaged(from: staging)
                try repair.restore()
            },
            loadPromoted: { promoted in
                try await FixtureModelLoader.loadPromoted(from: promoted)
            },
            progress: { _ in }
        )

        let revisionChildren = try fixture.fileManager.contentsOfDirectory(
            at: directory.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        let readiness = await fixture.store.readiness()
        XCTAssertEqual(prepared.modelDirectory, directory)
        XCTAssertEqual(readiness, .ready(modelDirectory: directory))
        XCTAssertFalse(revisionChildren.contains {
            $0.lastPathComponent.hasPrefix("snapshot-backup-")
        })
    }

    func testLoaderDerivedTokenizerIsReceiptedBeforePromotionAndIsNotPublicProvenance() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let directory = try await fixture.prepare(allowDownload: true)

        let derivedReceipt = directory.appendingPathComponent(LocalSpeechModelStore.derivedReceiptName)
        let receipt = try String(contentsOf: derivedReceipt, encoding: .utf8)
        XCTAssertTrue(receipt.contains("Qwen3TTSModel.fromModelDirectory"))
        XCTAssertTrue(receipt.contains("tokenizer.json"))
        XCTAssertFalse(receipt.contains(fixture.temporaryRoot.path))
        XCTAssertEqual(fixture.manifest.files.count, 2)
        let readiness = await fixture.store.readiness()
        XCTAssertEqual(readiness, .ready(modelDirectory: directory))
    }

    func testMissingDerivedReceiptIsNeverReady() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let directory = try await fixture.prepare(allowDownload: true)

        try fixture.fileManager.removeItem(
            at: directory.appendingPathComponent(LocalSpeechModelStore.derivedReceiptName)
        )

        let readiness = await fixture.store.readiness()
        XCTAssertEqual(readiness, .unavailable(.derivedTokenizerInvalid))
    }

    func testLoaderFailureNeverPromotesVerifiedPublicFiles() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        do {
            _ = try await fixture.store.prepare(
                allowDownload: true,
                validateStagedLoad: { _ in throw FixtureLoaderFailure.failed },
                loadPromoted: { _ in FixtureLoadedModel() },
                progress: { _ in }
            )
            XCTFail("loader failure must keep the public snapshot in staging")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .loaderValidationFailed)
        }

        let readiness = await fixture.store.readiness()
        XCTAssertEqual(readiness, .notInstalled)
        let snapshots = try fixture.findDirectories(named: "snapshot")
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testNewInstallPostPromotionLoaderFailureRemovesPromotedCandidate() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        do {
            _ = try await fixture.store.prepare(
                allowDownload: true,
                validateStagedLoad: { directory in
                    try await FixtureModelLoader.validateStaged(from: directory)
                },
                loadPromoted: { _ in throw FixtureLoaderFailure.failed },
                progress: { _ in }
            )
            XCTFail("a failed first promoted load must not remain installed")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .loaderValidationFailed)
        }

        let readiness = await fixture.store.readiness()
        let snapshots = try fixture.findDirectories(named: "snapshot")
        XCTAssertEqual(readiness, .notInstalled)
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testCancellationAfterWeaklyCancellableStagedLoaderReturnsNeverPromotes() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let gate = NoncancellableLoaderGate()
        let finalLoad = InvocationCounter()

        let task = Task {
            try await fixture.store.prepare(
                allowDownload: true,
                validateStagedLoad: { directory in
                    let tokenizer = directory.appendingPathComponent(
                        LocalSpeechModelStore.derivedTokenizerName
                    )
                    try Data(#"{"model":{"type":"BPE"}}"#.utf8).write(to: tokenizer)
                    await gate.wait()
                },
                loadPromoted: { _ in
                    finalLoad.increment()
                    return FixtureLoadedModel()
                },
                progress: { _ in }
            )
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("cancellation observed after staged load must stop promotion")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .cancelled)
        }
        XCTAssertEqual(finalLoad.value, 0)
        let readiness = await fixture.store.readiness()
        XCTAssertEqual(readiness, .notInstalled)
        let snapshots = try fixture.findDirectories(named: "snapshot")
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testLoadRejectsSameSizeTamperWhetherMetadataGateDetectsItFirst() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let directory = try await fixture.prepare(allowDownload: true)
        let config = directory.appendingPathComponent("config.json")
        let attributes = try fixture.fileManager.attributesOfItem(atPath: config.path)
        let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let original = try Data(contentsOf: config)
        try Data(repeating: 0x58, count: original.count).write(to: config)
        try fixture.fileManager.setAttributes([.modificationDate: date], ofItemAtPath: config.path)

        // Filesystems differ in how precisely Foundation restores a modified
        // timestamp. The cheap readiness signature may therefore catch this
        // tamper immediately or leave it to prepare's mandatory full hash.
        let metadataReadiness = await fixture.store.readiness()
        switch metadataReadiness {
        case .ready(let readyDirectory):
            XCTAssertEqual(readyDirectory, directory)
        case .unavailable(let failure):
            XCTAssertEqual(failure, .hashMismatch)
        default:
            XCTFail("tampered installed bytes must remain present and fail closed")
        }
        do {
            _ = try await fixture.prepare(allowDownload: false)
            XCTFail("every load must run complete public-file hashes")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .hashMismatch)
        }
        let downloadCount = await fixture.downloader.callCount()
        XCTAssertEqual(downloadCount, 1)
    }

    func testExistingSymlinkedPrivateRootIsRejectedBeforeDownload() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let target = fixture.temporaryRoot.appendingPathComponent("symlink-target")
        try fixture.fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fixture.fileManager.createSymbolicLink(
            at: fixture.modelRoot,
            withDestinationURL: target
        )

        do {
            _ = try await fixture.prepare(allowDownload: true)
            XCTFail("a symlinked private model root must fail closed")
        } catch let failure as LocalSpeechModelStoreFailure {
            XCTAssertEqual(failure, .symbolicLinkRejected)
        }
        let downloadCount = await fixture.downloader.callCount()
        XCTAssertEqual(downloadCount, 0)
    }

    func testScopedRemovalDeletesOnlyExactModelRevision() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        _ = try await fixture.prepare(allowDownload: true)

        let unrelated = fixture.temporaryRoot.appendingPathComponent("SessionManifests/sentinel.json")
        try fixture.fileManager.createDirectory(
            at: unrelated.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: unrelated)

        try await fixture.store.removeInstalledRevision()

        let readiness = await fixture.store.readiness()
        let unrelatedData = try Data(contentsOf: unrelated)
        let revisionDirectories = try fixture.findDirectories(named: fixture.manifest.revision)
        XCTAssertEqual(readiness, .notInstalled)
        XCTAssertEqual(unrelatedData, Data("keep".utf8))
        XCTAssertFalse(revisionDirectories.contains {
            $0.path.contains("Models")
        })
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private struct Fixture {
    let temporaryRoot: URL
    let modelRoot: URL
    let manifest: LocalSpeechSnapshotManifest
    let downloader: FixtureDownloader
    let store: LocalSpeechModelStore
    let fileManager: FileManager

    static func make(
        behaviors: [FixtureDownloader.Behavior] = [.valid],
        availableBytes: Int64 = 1_000,
        minimumFreeBytes: Int64 = 100,
        manifestFiles: [LocalSpeechSnapshotFile]? = nil,
        derivesTokenizer: Bool = true,
        postReplacementValidation: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in }
    ) throws -> Fixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-qwen-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let modelRoot = root.appendingPathComponent("Models", isDirectory: true)
        let contents: [String: Data] = [
            "config.json": Data(#"{"sample_rate":24000}"#.utf8),
            "speech_tokenizer/model.safetensors": Data([1, 3, 3, 7]),
        ]
        let manifest = LocalSpeechSnapshotManifest(
            repositoryID: "fixture-org/fixture-model",
            revision: "0123456789abcdef0123456789abcdef01234567",
            files: manifestFiles ?? contents.keys.sorted().map { path in
                let data = contents[path]!
                return LocalSpeechSnapshotFile(
                    path: path,
                    byteCount: Int64(data.count),
                    sha256: LocalSpeechSHA256.string(data)
                )
            }
        )
        let downloader = FixtureDownloader(
            behaviors: behaviors,
            contents: contents,
            fileManager: FileManager()
        )
        let store = LocalSpeechModelStore(
            modelRoot: modelRoot,
            manifest: manifest,
            downloader: downloader,
            freeSpaceReader: FixedFreeSpaceReader(availableBytes: availableBytes),
            fileManager: FileManager(),
            minimumFreeBytes: minimumFreeBytes,
            derivesTokenizer: derivesTokenizer,
            postReplacementValidation: postReplacementValidation
        )
        return Fixture(
            temporaryRoot: root,
            modelRoot: modelRoot,
            manifest: manifest,
            downloader: downloader,
            store: store,
            fileManager: fileManager
        )
    }

    func remove() {
        try? fileManager.removeItem(at: temporaryRoot)
    }

    func prepare(
        allowDownload: Bool,
        progress: @escaping @Sendable (LocalSpeechModelStoreProgress) -> Void = { _ in }
    ) async throws -> URL {
        let prepared = try await store.prepare(
            allowDownload: allowDownload,
            validateStagedLoad: { directory in
                try await FixtureModelLoader.validateStaged(from: directory)
            },
            loadPromoted: { directory in
                try await FixtureModelLoader.loadPromoted(from: directory)
            },
            progress: progress
        )
        return prepared.modelDirectory
    }

    func findDirectories(named name: String) throws -> [URL] {
        guard fileManager.fileExists(atPath: temporaryRoot.path),
              let enumerator = fileManager.enumerator(
                  at: temporaryRoot,
                  includingPropertiesForKeys: [.isDirectoryKey]
              ) else {
            return []
        }
        var matches = [URL]()
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == name,
               try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                matches.append(url)
            }
        }
        return matches
    }

    func invalidateVerificationReceipt(in directory: URL) throws -> FixtureReceiptRepair {
        let receipt = directory.appendingPathComponent(LocalSpeechModelStore.verificationReceiptName)
        let repair = FixtureReceiptRepair(url: receipt, data: try Data(contentsOf: receipt))
        try fileManager.removeItem(at: receipt)
        return repair
    }
}

private struct FixtureReceiptRepair: Sendable {
    let url: URL
    let data: Data

    func restore() throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private enum FixtureLoaderFailure: Error {
    case failed
}

private final class FailFirstPostReplacementValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true
    private var sawBothDirectories = false

    func validate(final: URL, backup: URL) throws {
        let didSeeBoth = FileManager.default.fileExists(atPath: final.path)
            && FileManager.default.fileExists(atPath: backup.path)
        let fail = lock.withLock { () -> Bool in
            sawBothDirectories = sawBothDirectories || didSeeBoth
            guard shouldFail else { return false }
            shouldFail = false
            return true
        }
        if fail { throw LocalSpeechModelStoreFailure.storageFailure }
    }

    func didFailAfterSeeingBothDirectories() -> Bool {
        lock.withLock { sawBothDirectories && !shouldFail }
    }
}

private struct FixtureLoadedModel: Sendable {}

private enum FixtureModelLoader {
    static func validateStaged(from directory: URL) async throws {
        let tokenizer = directory.appendingPathComponent(LocalSpeechModelStore.derivedTokenizerName)
        try Data(#"{"model":{"type":"BPE"}}"#.utf8).write(to: tokenizer)
    }

    static func loadPromoted(from directory: URL) async throws -> FixtureLoadedModel {
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(LocalSpeechModelStore.derivedTokenizerName).path
        ) else {
            throw FixtureLoaderFailure.failed
        }
        return FixtureLoadedModel()
    }
}

private struct FixedFreeSpaceReader: LocalSpeechFreeSpaceReading {
    let availableBytes: Int64

    func availableBytes(for location: URL) throws -> Int64 {
        _ = location
        return availableBytes
    }
}

private actor FixtureDownloader: LocalSpeechSnapshotDownloading {
    enum Behavior: Equatable, Sendable {
        case valid
        case missingFile
        case extraFile
        case zeroFile
        case truncatedFile
        case wrongHash
        case symbolicLinkFile
        case symbolicLinkRoot
        case waitForCancellation
        case downloadFailure

    }

    private var behaviors: [Behavior]
    private let contents: [String: Data]
    private let fileManager: FileManager
    private var observedRevisions = [String]()
    private var calls = 0
    private var callWaiters = [CheckedContinuation<Void, Never>]()

    init(behaviors: [Behavior], contents: [String: Data], fileManager: FileManager) {
        self.behaviors = behaviors
        self.contents = contents
        self.fileManager = fileManager
    }

    func downloadSnapshot(
        manifest: LocalSpeechSnapshotManifest,
        destination: URL,
        cacheRoot: URL,
        progress: @escaping @Sendable (LocalSpeechModelStoreProgress) -> Void
    ) async throws {
        calls += 1
        observedRevisions.append(manifest.revision)
        callWaiters.forEach { $0.resume() }
        callWaiters.removeAll()
        let behavior = behaviors.isEmpty ? .valid : behaviors.removeFirst()

        if behavior == .downloadFailure {
            throw LocalSpeechModelStoreFailure.downloadFailed
        }
        if behavior == .waitForCancellation {
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        }

        if behavior == .symbolicLinkRoot {
            try fileManager.removeItem(at: destination)
            let target = cacheRoot.appendingPathComponent("fixture-root", isDirectory: true)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try writeValidSnapshot(to: target)
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: target)
            return
        }

        try writeValidSnapshot(to: destination)
        let firstPath = manifest.files[0].path
        let first = destination.appendingPathComponent(firstPath)
        switch behavior {
        case .valid:
            break
        case .missingFile:
            try fileManager.removeItem(at: first)
        case .extraFile:
            try Data("extra".utf8).write(to: destination.appendingPathComponent("unexpected.txt"))
        case .zeroFile:
            try Data().write(to: first)
        case .truncatedFile:
            let data = try Data(contentsOf: first)
            try Data(data.dropLast()).write(to: first)
        case .wrongHash:
            let data = try Data(contentsOf: first)
            try Data(repeating: 0x7f, count: data.count).write(to: first)
        case .symbolicLinkFile:
            let target = cacheRoot.appendingPathComponent("fixture-link-target")
            try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            try Data(contentsOf: first).write(to: target)
            try fileManager.removeItem(at: first)
            try fileManager.createSymbolicLink(at: first, withDestinationURL: target)
        case .symbolicLinkRoot, .waitForCancellation, .downloadFailure:
            XCTFail("handled before snapshot mutation")
        }

        progress(
            LocalSpeechModelStoreProgress(
                stage: .downloading,
                completedBytes: manifest.byteCount,
                totalBytes: manifest.byteCount
            )
        )
    }

    func callCount() -> Int { calls }
    func revisions() -> [String] { observedRevisions }

    func waitUntilCalled() async {
        if calls > 0 { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    private func writeValidSnapshot(to destination: URL) throws {
        for (path, data) in contents {
            let url = destination.appendingPathComponent(path)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [LocalSpeechModelStoreProgress]()

    var values: [LocalSpeechModelStoreProgress] {
        lock.withLock { stored }
    }

    func append(_ value: LocalSpeechModelStoreProgress) {
        lock.withLock { stored.append(value) }
    }
}

private actor NoncancellableLoaderGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { waiter in
            startWaiters.append(waiter)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
