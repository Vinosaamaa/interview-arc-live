import Foundation
import XCTest

@testable import InterviewArcLiveLocalSpeechAdapter

@MainActor
final class LocalSpeechSnapshotMaterializerTests: XCTestCase {
    func testMaterializesHiddenAndNestedAllowlistedFilesFromPrivateCacheSymlinks() throws {
        let fixture = try MaterializerFixture.make()
        defer { fixture.remove() }

        try LocalSpeechSnapshotMaterializer().materialize(
            manifest: fixture.manifest,
            cachedSnapshot: fixture.snapshot,
            cacheRoot: fixture.cacheRoot,
            destination: fixture.destination
        )

        let hiddenData = try Data(
            contentsOf: fixture.destination.appendingPathComponent(".gitattributes")
        )
        let nestedData = try Data(
            contentsOf: fixture.destination.appendingPathComponent(
                "speech_tokenizer/model.safetensors"
            )
        )
        XCTAssertEqual(
            hiddenData,
            fixture.contents[".gitattributes"]
        )
        XCTAssertEqual(
            nestedData,
            fixture.contents["speech_tokenizer/model.safetensors"]
        )
        let entries = try fixture.relativeFiles(in: fixture.destination)
        XCTAssertEqual(entries, Set(fixture.contents.keys))
    }

    func testRejectsCacheSymlinkEscapingTheLiveOwnedCacheRoot() throws {
        let fixture = try MaterializerFixture.make(escapeCache: true)
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try LocalSpeechSnapshotMaterializer().materialize(
                manifest: fixture.manifest,
                cachedSnapshot: fixture.snapshot,
                cacheRoot: fixture.cacheRoot,
                destination: fixture.destination
            )
        ) { error in
            XCTAssertEqual(error as? LocalSpeechModelStoreFailure, .symbolicLinkRejected)
        }
    }

    func testCancellationCheckRunsBeforeCopyingAnyAllowlistedFile() throws {
        let fixture = try MaterializerFixture.make()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try LocalSpeechSnapshotMaterializer().materialize(
                manifest: fixture.manifest,
                cachedSnapshot: fixture.snapshot,
                cacheRoot: fixture.cacheRoot,
                destination: fixture.destination,
                cancellationCheck: { throw CancellationError() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let copiedFiles = try fixture.relativeFiles(in: fixture.destination)
        XCTAssertTrue(copiedFiles.isEmpty)
    }
}

private struct MaterializerFixture {
    let root: URL
    let cacheRoot: URL
    let snapshot: URL
    let destination: URL
    let contents: [String: Data]
    let manifest: LocalSpeechSnapshotManifest

    static func make(escapeCache: Bool = false) throws -> MaterializerFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-materializer-\(UUID().uuidString)",
            isDirectory: true
        )
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let snapshot = cache.appendingPathComponent(
            "models--fixture--model/snapshots/0123456789abcdef0123456789abcdef01234567",
            isDirectory: true
        )
        let blobs = cache.appendingPathComponent("models--fixture--model/blobs", isDirectory: true)
        let destination = root.appendingPathComponent("staging", isDirectory: true)
        try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let contents: [String: Data] = [
            ".gitattributes": Data("*.safetensors filter=lfs".utf8),
            "speech_tokenizer/model.safetensors": Data([2, 4, 0, 0, 0]),
        ]
        let manifest = LocalSpeechSnapshotManifest(
            repositoryID: "fixture/model",
            revision: "0123456789abcdef0123456789abcdef01234567",
            files: contents.keys.sorted().map { path in
                let data = contents[path]!
                return LocalSpeechSnapshotFile(
                    path: path,
                    byteCount: Int64(data.count),
                    sha256: LocalSpeechSHA256.string(data)
                )
            }
        )

        let escapingPath = ".gitattributes"
        for (index, path) in contents.keys.sorted().enumerated() {
            let data = contents[path]!
            let blob: URL
            if escapeCache, path == escapingPath {
                blob = root.appendingPathComponent("outside-blob")
            } else {
                blob = blobs.appendingPathComponent("blob-\(index)")
            }
            try data.write(to: blob)
            let link = snapshot.appendingPathComponent(path)
            try fileManager.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(at: link, withDestinationURL: blob)
        }

        return MaterializerFixture(
            root: root,
            cacheRoot: cache,
            snapshot: snapshot,
            destination: destination,
            contents: contents,
            manifest: manifest
        )
    }

    func relativeFiles(in directory: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var result = Set<String>()
        // `temporaryDirectory` can be spelled through `/var` while the
        // enumerator returns its canonical `/private/var` spelling on macOS.
        // Canonicalize both sides before deriving a relative fixture path.
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let directoryPath = canonicalDirectory.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        while let url = enumerator.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard filePath.hasPrefix(prefix) else {
                    throw MaterializerFixtureFailure.enumeratedPathEscapedRoot
                }
                result.insert(String(filePath.dropFirst(prefix.count)))
            }
        }
        return result
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum MaterializerFixtureFailure: Error {
    case enumeratedPathEscapedRoot
}
