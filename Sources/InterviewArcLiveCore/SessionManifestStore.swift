import Foundation

/// The persistence Seam for the canonical Session Manifest.
///
/// A save is a compare-and-swap operation: `expectedRevision` is `nil` only
/// when creating a session and otherwise names the exact durable revision the
/// caller is replacing. Adapters must reject a stale expectation without
/// changing the previously readable manifest.
public protocol SessionManifestStore: Sendable {
    func load(sessionID: SessionID) async throws -> SessionManifest?

    func save(
        _ manifest: SessionManifest,
        expectedRevision: Int?
    ) async throws
}

public enum SessionManifestStoreError: Error, Equatable, Sendable {
    case revisionConflict(expected: Int?, actual: Int?)
    case nonMonotonicRevision(previous: Int, proposed: Int)
    case sessionIdentityMismatch
    case fileLockFailed(operation: String, code: Int32)
}

/// A deterministic Adapter for tests and ephemeral previews.
public actor InMemorySessionManifestStore: SessionManifestStore {
    private var manifests: [SessionID: SessionManifest]

    public init(manifests: [SessionManifest] = []) {
        self.manifests = Dictionary(
            uniqueKeysWithValues: manifests.map { ($0.sessionID, $0) }
        )
    }

    public func load(sessionID: SessionID) -> SessionManifest? {
        manifests[sessionID]
    }

    public func save(
        _ manifest: SessionManifest,
        expectedRevision: Int?
    ) throws {
        let current = manifests[manifest.sessionID]
        let actualRevision = current?.revision

        guard actualRevision == expectedRevision else {
            throw SessionManifestStoreError.revisionConflict(
                expected: expectedRevision,
                actual: actualRevision
            )
        }

        if let actualRevision, manifest.revision <= actualRevision {
            throw SessionManifestStoreError.nonMonotonicRevision(
                previous: actualRevision,
                proposed: manifest.revision
            )
        }

        manifests[manifest.sessionID] = manifest
    }
}
