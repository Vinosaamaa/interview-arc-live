import CryptoKit
import Foundation

public enum LiveOutboxPhase: String, Codable, Equatable, Sendable {
    case prepared
    case ambiguous
    case receiptConfirmed
    case recoveryRequired
}

public struct LiveOutboxRecord: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let operationId: String
    public let operation: String
    public let method: LiveV1HTTPMethod
    public let pathSuffix: String
    public let activityId: String
    public let workbenchId: String
    public let holderId: String
    public let holderSessionId: String
    public let fencingToken: Int?
    public let dependencyOperationId: String?
    public let payloadDigest: String
    public let canonicalBody: Data
    public let localContentReference: String?
    public let uploadHeaders: [String: String]?
    public let credentialFingerprint: String
    public let createdAt: LiveEpochMilliseconds
    public var phase: LiveOutboxPhase
    public var lastSafeErrorCode: String?

    public var id: String { operationId }

    public init(
        operationId: String,
        operation: String,
        method: LiveV1HTTPMethod = .post,
        pathSuffix: String,
        activityId: String,
        workbenchId: String,
        holderId: String,
        holderSessionId: String,
        fencingToken: Int?,
        dependencyOperationId: String?,
        canonicalBody: Data,
        localContentReference: String? = nil,
        uploadHeaders: [String: String]? = nil,
        credentialFingerprint: String,
        createdAt: LiveEpochMilliseconds
    ) {
        self.schemaVersion = 1
        self.operationId = operationId
        self.operation = operation
        self.method = method
        self.pathSuffix = pathSuffix
        self.activityId = activityId
        self.workbenchId = workbenchId
        self.holderId = holderId
        self.holderSessionId = holderSessionId
        self.fencingToken = fencingToken
        self.dependencyOperationId = dependencyOperationId
        self.payloadDigest = SHA256.hash(data: canonicalBody)
            .map { String(format: "%02x", $0) }
            .joined()
        self.canonicalBody = canonicalBody
        self.localContentReference = localContentReference
        self.uploadHeaders = uploadHeaders
        self.credentialFingerprint = credentialFingerprint
        self.createdAt = createdAt
        self.phase = .prepared
        self.lastSafeErrorCode = nil
    }
}

public enum PrivateLiveOutboxStoreError: Error, Equatable, Sendable {
    case operationIdentityConflict
    case partitionMismatch
    case dependencyCycle
}

public struct LiveOutboxSummary: Equatable, Sendable {
    public let count: Int
    public let latestOperationID: String?
}

public actor PrivateLiveOutboxStore {
    private struct Envelope: Codable, Equatable, Sendable {
        let schemaVersion: Int
        var records: [LiveOutboxRecord]
    }

    private let hierarchy: [URL]
    private let directoryURL: URL

    public init() throws {
        let (baseHierarchy, placeholder) = try PrivateLiveJSONStore.hostedHierarchy(
            leaf: "Outbox"
        )
        hierarchy = baseHierarchy + [placeholder]
        directoryURL = placeholder
    }

    public init(directoryURL: URL) {
        hierarchy = [directoryURL]
        self.directoryURL = directoryURL
    }

    public func records(
        credentialFingerprint: String
    ) throws -> [LiveOutboxRecord] {
        let records = try load(credentialFingerprint).records
        let recordIDs = Set(records.map(\.operationId))
        var emitted = Set<String>()
        var remaining = records
        var ordered: [LiveOutboxRecord] = []

        while !remaining.isEmpty {
            let ready = remaining.filter { record in
                guard let dependency = record.dependencyOperationId,
                      recordIDs.contains(dependency) else { return true }
                return emitted.contains(dependency)
            }.sorted(by: Self.stableOrder)

            guard !ready.isEmpty else {
                throw PrivateLiveOutboxStoreError.dependencyCycle
            }
            let readyIDs = Set(ready.map(\.operationId))
            ordered.append(contentsOf: ready)
            emitted.formUnion(readyIDs)
            remaining.removeAll { readyIDs.contains($0.operationId) }
        }
        return ordered
    }

    private static func stableOrder(
        _ lhs: LiveOutboxRecord,
        _ rhs: LiveOutboxRecord
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.operationId < rhs.operationId
        }
        return lhs.createdAt < rhs.createdAt
    }

    public func summary(
        credentialFingerprint: String
    ) throws -> LiveOutboxSummary {
        let records = try records(credentialFingerprint: credentialFingerprint)
        return LiveOutboxSummary(
            count: records.count,
            latestOperationID: records.last?.operationId
        )
    }

    public func prepare(_ record: LiveOutboxRecord) throws {
        guard record.credentialFingerprint.count == 64 else {
            throw PrivateLiveOutboxStoreError.partitionMismatch
        }
        var envelope = try load(record.credentialFingerprint)
        if let existing = envelope.records.first(where: {
            $0.operationId == record.operationId
        }) {
            guard existing.payloadDigest == record.payloadDigest,
                  existing.activityId == record.activityId,
                  existing.operation == record.operation else {
                throw PrivateLiveOutboxStoreError.operationIdentityConflict
            }
            return
        }
        envelope.records.append(record)
        try store(record.credentialFingerprint).save(envelope)
    }

    public func mark(
        operationID: String,
        credentialFingerprint: String,
        phase: LiveOutboxPhase,
        lastSafeErrorCode: String? = nil
    ) throws {
        var envelope = try load(credentialFingerprint)
        guard let index = envelope.records.firstIndex(where: {
            $0.operationId == operationID
        }) else { return }
        envelope.records[index].phase = phase
        envelope.records[index].lastSafeErrorCode = lastSafeErrorCode
        try store(credentialFingerprint).save(envelope)
    }

    public func remove(
        operationID: String,
        credentialFingerprint: String
    ) throws {
        var envelope = try load(credentialFingerprint)
        envelope.records.removeAll { $0.operationId == operationID }
        try store(credentialFingerprint).save(envelope)
    }

    public func hasQuarantinedPartitions(
        excluding credentialFingerprint: String
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return false
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return files.contains {
            $0.pathExtension == "json"
                && $0.deletingPathExtension().lastPathComponent != credentialFingerprint
        }
    }

    private func load(_ fingerprint: String) throws -> Envelope {
        try store(fingerprint).load(Envelope.self)
            ?? Envelope(schemaVersion: 1, records: [])
    }

    private func store(_ fingerprint: String) throws -> PrivateLiveJSONStore {
        guard fingerprint.count == 64,
              fingerprint.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw PrivateLiveOutboxStoreError.partitionMismatch
        }
        return PrivateLiveJSONStore(
            directoryHierarchy: hierarchy,
            fileURL: directoryURL.appendingPathComponent("\(fingerprint).json")
        )
    }
}
