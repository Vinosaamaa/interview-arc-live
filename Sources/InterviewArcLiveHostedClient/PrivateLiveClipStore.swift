import CryptoKit
import Foundation
import InterviewArcLiveCore

public struct PrivateLiveClipIntent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let clipId: String
    public let candidateTurnId: String
    public let mimeType: String
    public let byteSize: Int
    public let sha256: String
    public let contentReference: String

    public init(
        clipId: String,
        candidateTurnId: String,
        mimeType: String,
        byteSize: Int,
        sha256: String,
        contentReference: String
    ) {
        self.schemaVersion = 1
        self.clipId = clipId
        self.candidateTurnId = candidateTurnId
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.contentReference = contentReference
    }
}

public actor PrivateLiveClipStore {
    private let hierarchy: [URL]
    private let directoryURL: URL

    public init() throws {
        let (baseHierarchy, clips) = try PrivateLiveJSONStore.hostedHierarchy(
            leaf: "Clips"
        )
        hierarchy = baseHierarchy + [clips]
        directoryURL = clips
    }

    public init(directoryURL: URL) {
        hierarchy = [directoryURL]
        self.directoryURL = directoryURL
    }

    public func persist(
        clipID: String,
        candidateTurnID: String,
        mimeType: String,
        data: Data
    ) async throws -> PrivateLiveClipIntent {
        guard Self.validID(clipID),
              Self.validID(candidateTurnID),
              !data.isEmpty,
              data.count <= 104_857_600 else {
            throw HostedPracticeSessionError.invalidClip
        }
        let reference = "\(clipID).content"
        let contentStore = try contentStore(reference)
        let metadataStore = metadataStore(clipID)
        let sha256 = await Self.digest(data)
        let intent = PrivateLiveClipIntent(
            clipId: clipID,
            candidateTurnId: candidateTurnID,
            mimeType: mimeType,
            byteSize: data.count,
            sha256: sha256,
            contentReference: reference
        )
        try await Task.detached(priority: .utility) {
            try contentStore.saveData(data)
            try metadataStore.save(intent)
        }.value
        return intent
    }

    public func loadContent(reference: String) async throws -> Data {
        guard Self.validReference(reference) else {
            throw HostedPracticeSessionError.invalidClip
        }
        let store = try contentStore(reference)
        guard let data = try await Task.detached(priority: .utility, operation: {
            try store.loadData()
        }).value else {
            throw HostedPracticeSessionError.invalidClip
        }
        return data
    }

    public func loadIntent(clipID: String) async throws -> PrivateLiveClipIntent? {
        guard Self.validID(clipID) else {
            throw HostedPracticeSessionError.invalidClip
        }
        let store = metadataStore(clipID)
        return try await Task.detached(priority: .utility) {
            try store.load(PrivateLiveClipIntent.self)
        }.value
    }

    public func verify(_ intent: PrivateLiveClipIntent) async throws -> Data {
        let data = try await loadContent(reference: intent.contentReference)
        return try await verify(intent, content: data)
    }

    public func verify(
        _ intent: PrivateLiveClipIntent,
        content: Data
    ) async throws -> Data {
        let digest = await Self.digest(content)
        guard content.count == intent.byteSize, digest == intent.sha256 else {
            throw HostedPracticeSessionError.invalidClip
        }
        return content
    }

    public func remove(_ intent: PrivateLiveClipIntent) async throws {
        let targets = [
            directoryURL.appendingPathComponent(intent.contentReference),
            directoryURL.appendingPathComponent("\(intent.clipId).json"),
        ]
        try await Task.detached(priority: .utility) {
            for target in targets where FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        }.value
    }

    private func contentStore(_ reference: String) throws -> PrivateLiveJSONStore {
        guard Self.validReference(reference) else {
            throw HostedPracticeSessionError.invalidClip
        }
        return PrivateLiveJSONStore(
            directoryHierarchy: hierarchy,
            fileURL: directoryURL.appendingPathComponent(reference)
        )
    }

    private func metadataStore(_ clipID: String) -> PrivateLiveJSONStore {
        PrivateLiveJSONStore(
            directoryHierarchy: hierarchy,
            fileURL: directoryURL.appendingPathComponent("\(clipID).json")
        )
    }

    private static func validID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._:-")
        )
        return value.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validReference(_ value: String) -> Bool {
        value.hasSuffix(".content")
            && !value.contains("/")
            && !value.contains("..")
            && validID(String(value.dropLast(".content".count)))
    }

    private nonisolated static func digest(_ data: Data) async -> String {
        await Task.detached(priority: .utility) {
            SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }.value
    }
}
