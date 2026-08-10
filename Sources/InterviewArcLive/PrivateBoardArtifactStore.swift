import CryptoKit
import Darwin
import Foundation
import InterviewArcLiveCore

enum PrivateBoardArtifactStoreError: Error, Equatable, Sendable {
    case unsafeStorage
    case invalidIdentities
    case artifactTooLarge
    case invalidCanonicalSource
    case invalidSVG
    case invalidPNG
    case corruptManifest
    case missingBundle
}

enum PrivateBoardArtifactRecovery: Equatable, Sendable {
    case missing
    case needsRegeneration(source: Data)
    case complete(BoardArtifactBundle)
}

/// Stores one authorized source/SVG/PNG set by atomically promoting a private
/// directory only after every member and the integrity manifest validates.
actor PrivateBoardArtifactStore {
    static let maximumSourceBytes = 2 * 1_024 * 1_024
    static let maximumSVGBytes = 4 * 1_024 * 1_024
    static let maximumPNGBytes = 64 * 1_024 * 1_024

    private struct BundleManifest: Codable, Equatable {
        let schemaVersion: Int
        let exportID: String
        let bundle: BoardArtifactBundle
    }

    private struct Locations {
        let parent: URL
        let finalDirectory: URL
        let sourceName: String
        let svgName: String
        let pngName: String
    }

    private let root: URL
    private let fileManager: FileManager
    private let codec: DrawIOBoardCodec
    private let postPromotionValidation: @Sendable (URL) throws -> Void

    init(
        root: URL,
        fileManager: FileManager = .default,
        codec: DrawIOBoardCodec = DrawIOBoardCodec(),
        postPromotionValidation: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.codec = codec
        self.postPromotionValidation = postPromotionValidation
    }

    func persist(
        exportID: BoardExportID,
        identities: BoardArtifactIdentities,
        artifacts: RenderedBoardArtifacts
    ) throws -> BoardArtifactBundle {
        try validate(artifacts)
        let locations = try locations(for: identities)
        let token = digest(identities.source.rawValue)
        try ensurePrivateDirectory(root)
        try ensurePrivateDirectory(locations.parent)
        try restorePreviousIfNecessary(
            locations: locations,
            identities: identities,
            token: token
        )
        try cleanupPartial(in: locations.parent, token: token)

        let expected = try metadata(
            identities: identities,
            source: artifacts.canonicalSource,
            svg: artifacts.svg,
            png: artifacts.png
        )
        if fileManager.fileExists(atPath: locations.finalDirectory.path),
           case .complete(let existing) = try recover(identities: identities),
           existing == expected {
            return existing
        }

        let staging = locations.parent.appendingPathComponent(
            ".board-export-\(token).partial",
            isDirectory: true
        )
        let previous = locations.parent.appendingPathComponent(
            ".board-export-\(token).previous",
            isDirectory: true
        )
        try removeOwnedTemporaryItemIfPresent(staging)
        try removeOwnedTemporaryItemIfPresent(previous)
        try createPrivateDirectory(staging)

        var movedPrevious = false
        var promoted = false
        do {
            try writePrivate(artifacts.canonicalSource, to: staging.appendingPathComponent(locations.sourceName))
            try writePrivate(artifacts.svg, to: staging.appendingPathComponent(locations.svgName))
            try writePrivate(artifacts.png, to: staging.appendingPathComponent(locations.pngName))
            let manifest = BundleManifest(
                schemaVersion: 1,
                exportID: exportID.rawValue,
                bundle: expected
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writePrivate(
                encoder.encode(manifest),
                to: staging.appendingPathComponent("bundle.json")
            )
            try synchronizeDirectory(staging)
            _ = try validateCompleteBundle(
                at: staging,
                identities: identities,
                expectedExportID: exportID.rawValue
            )

            if fileManager.fileExists(atPath: locations.finalDirectory.path) {
                try fileManager.moveItem(at: locations.finalDirectory, to: previous)
                movedPrevious = true
                try synchronizeDirectory(locations.parent)
            }
            try fileManager.moveItem(at: staging, to: locations.finalDirectory)
            promoted = true
            try synchronizeDirectory(locations.parent)
            let promotedBundle = try validateCompleteBundle(
                at: locations.finalDirectory,
                identities: identities,
                expectedExportID: exportID.rawValue
            )
            guard promotedBundle == expected else {
                throw PrivateBoardArtifactStoreError.corruptManifest
            }
            try postPromotionValidation(locations.finalDirectory)
            if movedPrevious {
                try fileManager.removeItem(at: previous)
                try synchronizeDirectory(locations.parent)
            }
            return promotedBundle
        } catch {
            if promoted {
                try? fileManager.removeItem(at: locations.finalDirectory)
            } else {
                try? fileManager.removeItem(at: staging)
            }
            if movedPrevious,
               fileManager.fileExists(atPath: previous.path),
               !fileManager.fileExists(atPath: locations.finalDirectory.path) {
                try? fileManager.moveItem(at: previous, to: locations.finalDirectory)
            }
            try? synchronizeDirectory(locations.parent)
            throw error
        }
    }

    func recover(
        identities: BoardArtifactIdentities
    ) throws -> PrivateBoardArtifactRecovery {
        let locations = try locations(for: identities)
        let token = digest(identities.source.rawValue)
        guard fileManager.fileExists(atPath: root.path) else { return .missing }
        try validatePrivateDirectory(root)
        if fileManager.fileExists(atPath: locations.parent.path) {
            try validatePrivateDirectory(locations.parent)
            try restorePreviousIfNecessary(
                locations: locations,
                identities: identities,
                token: token
            )
            try cleanupPartial(in: locations.parent, token: token)
        }
        guard fileManager.fileExists(atPath: locations.finalDirectory.path) else {
            return .missing
        }
        try validatePrivateDirectory(locations.finalDirectory)

        let sourceURL = locations.finalDirectory.appendingPathComponent(
            locations.sourceName
        )
        let source = try readPrivate(
            sourceURL,
            maximumBytes: Self.maximumSourceBytes
        )
        guard let sourceString = String(data: source, encoding: .utf8) else {
            throw PrivateBoardArtifactStoreError.invalidCanonicalSource
        }
        do {
            _ = try codec.decode(sourceString)
        } catch {
            throw PrivateBoardArtifactStoreError.invalidCanonicalSource
        }

        do {
            let bundle = try validateCompleteBundle(
                at: locations.finalDirectory,
                identities: identities,
                expectedExportID: nil
            )
            return .complete(bundle)
        } catch PrivateBoardArtifactStoreError.invalidSVG,
                PrivateBoardArtifactStoreError.invalidPNG,
                PrivateBoardArtifactStoreError.corruptManifest {
            return .needsRegeneration(source: source)
        } catch {
            if !fileManager.fileExists(
                atPath: locations.finalDirectory
                    .appendingPathComponent(locations.svgName).path
            ) || !fileManager.fileExists(
                atPath: locations.finalDirectory
                    .appendingPathComponent(locations.pngName).path
            ) || !fileManager.fileExists(
                atPath: locations.finalDirectory
                    .appendingPathComponent("bundle.json").path
            ) {
                return .needsRegeneration(source: source)
            }
            throw error
        }
    }

    func readSource(identities: BoardArtifactIdentities) throws -> Data {
        let recovery = try recover(identities: identities)
        switch recovery {
        case .missing:
            throw PrivateBoardArtifactStoreError.missingBundle
        case .needsRegeneration(let source):
            return source
        case .complete:
            let locations = try locations(for: identities)
            return try readPrivate(
                locations.finalDirectory.appendingPathComponent(locations.sourceName),
                maximumBytes: Self.maximumSourceBytes
            )
        }
    }

    private func validate(_ artifacts: RenderedBoardArtifacts) throws {
        guard artifacts.canonicalSource.count <= Self.maximumSourceBytes,
              artifacts.svg.count <= Self.maximumSVGBytes,
              artifacts.png.count <= Self.maximumPNGBytes else {
            throw PrivateBoardArtifactStoreError.artifactTooLarge
        }
        guard let source = String(data: artifacts.canonicalSource, encoding: .utf8),
              (try? codec.decode(source)) != nil else {
            throw PrivateBoardArtifactStoreError.invalidCanonicalSource
        }
        try validateSVG(artifacts.svg)
        try validatePNG(artifacts.png)
    }

    private func locations(for identities: BoardArtifactIdentities) throws -> Locations {
        let sourceParts = identities.source.rawValue.split(separator: "/").map(String.init)
        let svgParts = identities.svg.rawValue.split(separator: "/").map(String.init)
        let pngParts = identities.png.rawValue.split(separator: "/").map(String.init)
        guard sourceParts.count >= 2,
              sourceParts.dropLast() == svgParts.dropLast(),
              sourceParts.dropLast() == pngParts.dropLast(),
              sourceParts.last?.hasSuffix(".drawio") == true,
              svgParts.last?.hasSuffix(".svg") == true,
              pngParts.last?.hasSuffix(".png") == true,
              Set([sourceParts.last!, svgParts.last!, pngParts.last!]).count == 3 else {
            throw PrivateBoardArtifactStoreError.invalidIdentities
        }
        let directoryParts = sourceParts.dropLast()
        let parentParts = directoryParts.dropLast()
        let finalName = try required(directoryParts.last)
        let parent = parentParts.reduce(root) { url, component in
            url.appendingPathComponent(component, isDirectory: true)
        }.standardizedFileURL
        let finalDirectory = parent.appendingPathComponent(
            finalName,
            isDirectory: true
        ).standardizedFileURL
        guard isDescendant(parent, of: root),
              isDescendant(finalDirectory, of: root) else {
            throw PrivateBoardArtifactStoreError.invalidIdentities
        }
        return Locations(
            parent: parent,
            finalDirectory: finalDirectory,
            sourceName: try required(sourceParts.last),
            svgName: try required(svgParts.last),
            pngName: try required(pngParts.last)
        )
    }

    private func metadata(
        identities: BoardArtifactIdentities,
        source: Data,
        svg: Data,
        png: Data
    ) throws -> BoardArtifactBundle {
        BoardArtifactBundle(
            source: BoardArtifactMetadata(
                identity: identities.source,
                byteCount: source.count,
                sha256: sha256(source)
            ),
            svg: BoardArtifactMetadata(
                identity: identities.svg,
                byteCount: svg.count,
                sha256: sha256(svg)
            ),
            png: BoardArtifactMetadata(
                identity: identities.png,
                byteCount: png.count,
                sha256: sha256(png)
            )
        )
    }

    private func validateCompleteBundle(
        at directory: URL,
        identities: BoardArtifactIdentities,
        expectedExportID: String?
    ) throws -> BoardArtifactBundle {
        try validatePrivateDirectory(directory)
        let locations = try locations(for: identities)
        let source = try readPrivate(
            directory.appendingPathComponent(locations.sourceName),
            maximumBytes: Self.maximumSourceBytes
        )
        let svg = try readPrivate(
            directory.appendingPathComponent(locations.svgName),
            maximumBytes: Self.maximumSVGBytes
        )
        let png = try readPrivate(
            directory.appendingPathComponent(locations.pngName),
            maximumBytes: Self.maximumPNGBytes
        )
        guard let sourceString = String(data: source, encoding: .utf8),
              (try? codec.decode(sourceString)) != nil else {
            throw PrivateBoardArtifactStoreError.invalidCanonicalSource
        }
        try validateSVG(svg)
        try validatePNG(png)
        let computed = try metadata(
            identities: identities,
            source: source,
            svg: svg,
            png: png
        )
        let manifestData = try readPrivate(
            directory.appendingPathComponent("bundle.json"),
            maximumBytes: 64 * 1_024
        )
        let manifest: BundleManifest
        do {
            manifest = try JSONDecoder().decode(BundleManifest.self, from: manifestData)
        } catch {
            throw PrivateBoardArtifactStoreError.corruptManifest
        }
        guard manifest.schemaVersion == 1,
              manifest.bundle == computed,
              expectedExportID == nil || manifest.exportID == expectedExportID else {
            throw PrivateBoardArtifactStoreError.corruptManifest
        }
        return computed
    }

    private func validateSVG(_ data: Data) throws {
        guard let source = String(data: data, encoding: .utf8),
              source.utf8.count <= Self.maximumSVGBytes else {
            throw PrivateBoardArtifactStoreError.invalidSVG
        }
        let folded = source.lowercased()
        guard folded.contains("<svg "),
              !["<!doctype", "<!entity", "<script", "<foreignobject",
                "xlink:href=", " href=", " src=", "url(http", "url(file",
                "url(data"].contains(where: folded.contains) else {
            throw PrivateBoardArtifactStoreError.invalidSVG
        }
    }

    private func validatePNG(_ data: Data) throws {
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard data.count >= 24,
              data.prefix(8) == signature,
              data[12..<16] == Data("IHDR".utf8) else {
            throw PrivateBoardArtifactStoreError.invalidPNG
        }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width > 0, height > 0 else {
            throw PrivateBoardArtifactStoreError.invalidPNG
        }
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var cursor = root
        try enforcePrivateDirectory(cursor)
        let rootComponents = root.pathComponents
        for component in directory.standardizedFileURL.pathComponents.dropFirst(rootComponents.count) {
            cursor.appendPathComponent(component, isDirectory: true)
            try enforcePrivateDirectory(cursor)
        }
    }

    private func createPrivateDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try enforcePrivateDirectory(directory)
    }

    private func enforcePrivateDirectory(_ directory: URL) throws {
        try validateNotSymbolicLink(directory)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try validatePrivateDirectory(directory)
    }

    private func validatePrivateDirectory(_ directory: URL) throws {
        try validateNotSymbolicLink(directory)
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
                == 0o700 else {
            throw PrivateBoardArtifactStoreError.unsafeStorage
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw PrivateBoardArtifactStoreError.unsafeStorage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw PrivateBoardArtifactStoreError.unsafeStorage
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try validatePrivateFile(url)
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private func readPrivate(_ url: URL, maximumBytes: Int) throws -> Data {
        try validatePrivateFile(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= 0, size <= maximumBytes else {
            throw PrivateBoardArtifactStoreError.artifactTooLarge
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func validatePrivateFile(_ url: URL) throws {
        try validateNotSymbolicLink(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
                == 0o600 else {
            throw PrivateBoardArtifactStoreError.unsafeStorage
        }
    }

    private func validateNotSymbolicLink(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw PrivateBoardArtifactStoreError.unsafeStorage
        }
    }

    private func cleanupPartial(in parent: URL, token: String) throws {
        let partial = parent.appendingPathComponent(
            ".board-export-\(token).partial",
            isDirectory: true
        )
        try removeOwnedTemporaryItemIfPresent(partial)
    }

    private func restorePreviousIfNecessary(
        locations: Locations,
        identities: BoardArtifactIdentities,
        token: String
    ) throws {
        guard !fileManager.fileExists(atPath: locations.finalDirectory.path) else {
            return
        }
        let candidate = locations.parent.appendingPathComponent(
            ".board-export-\(token).previous",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              (try? validateCompleteBundle(
                at: candidate,
                identities: identities,
                expectedExportID: nil
              )) != nil else {
            return
        }
        try fileManager.moveItem(at: candidate, to: locations.finalDirectory)
        try synchronizeDirectory(locations.parent)
    }

    private func removeOwnedTemporaryItemIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw PrivateBoardArtifactStoreError.unsafeStorage
        }
        try fileManager.removeItem(at: url)
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PrivateBoardArtifactStoreError.unsafeStorage
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PrivateBoardArtifactStoreError.unsafeStorage
        }
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw PrivateBoardArtifactStoreError.invalidIdentities }
        return value
    }

    private func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        candidate.path == parent.path || candidate.path.hasPrefix(parent.path + "/")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func digest(_ value: String) -> String {
        String(sha256(Data(value.utf8)).prefix(16))
    }
}
