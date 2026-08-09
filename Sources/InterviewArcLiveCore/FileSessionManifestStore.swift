import Darwin
import Foundation

/// Atomic local-file Adapter for the Session Manifest persistence Seam.
///
/// Each replacement is prepared beside its destination, then renamed over the
/// prior manifest. If encoding, writing, or replacement fails, the last
/// complete destination remains readable.
public actor FileSessionManifestStore: SessionManifestStore {
    private let directoryURL: URL
    private let replace: @Sendable (_ destination: URL, _ prepared: URL) throws -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.init(directoryURL: directoryURL) { destination, prepared in
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: prepared,
                backupItemName: nil,
                options: []
            )
        }
    }

    public init() throws {
        self.init(
            directoryURL: try LivePaths.sessionManifestsDirectory()
        )
    }

    init(
        directoryURL: URL,
        replace: @escaping @Sendable (
            _ destination: URL,
            _ prepared: URL
        ) throws -> Void
    ) {
        self.directoryURL = directoryURL
        self.replace = replace

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load(sessionID: SessionID) throws -> SessionManifest? {
        try prepareDirectory()
        return try withLock(sessionID: sessionID, mode: LOCK_SH) {
            try loadUnlocked(sessionID: sessionID)
        }
    }

    private func loadUnlocked(sessionID: SessionID) throws -> SessionManifest? {
        let manifestURL = try manifestURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifest = try decoder.decode(
            SessionManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        guard manifest.sessionID == sessionID else {
            throw SessionManifestStoreError.sessionIdentityMismatch
        }

        return manifest
    }

    public func save(
        _ manifest: SessionManifest,
        expectedRevision: Int?
    ) throws {
        try prepareDirectory()

        try withLock(sessionID: manifest.sessionID, mode: LOCK_EX) {
            try saveUnlocked(manifest, expectedRevision: expectedRevision)
        }
    }

    private func saveUnlocked(
        _ manifest: SessionManifest,
        expectedRevision: Int?
    ) throws {
        let destination = try manifestURL(for: manifest.sessionID)
        let current = try loadUnlocked(sessionID: manifest.sessionID)
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

        let prepared = directoryURL.appendingPathComponent(
            ".manifest-\(UUID().uuidString).prepared",
            isDirectory: false
        )

        defer {
            try? FileManager.default.removeItem(at: prepared)
        }

        try encoder.encode(manifest).write(to: prepared, options: [.atomic])

        if current == nil {
            try FileManager.default.moveItem(at: prepared, to: destination)
        } else {
            try replace(destination, prepared)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// `flock` coordinates distinct Adapter instances and processes. The lock
    /// stays held for the complete expected-revision read and atomic replace.
    private func withLock<Result>(
        sessionID: SessionID,
        mode: Int32,
        operation: () throws -> Result
    ) throws -> Result {
        let lockURL = try lockURL(for: sessionID)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw lockError(operation: "open")
        }
        defer { Darwin.close(descriptor) }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw lockError(operation: "chmod")
        }

        while flock(descriptor, mode) != 0 {
            if errno != EINTR {
                throw lockError(operation: "lock")
            }
        }
        defer {
            while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
        }

        return try operation()
    }

    private func lockError(operation: String) -> SessionManifestStoreError {
        .fileLockFailed(operation: operation, code: errno)
    }

    private func manifestURL(for sessionID: SessionID) throws -> URL {
        directoryURL.appendingPathComponent(
            "\(try fileName(for: sessionID)).json",
            isDirectory: false
        )
    }

    private func lockURL(for sessionID: SessionID) throws -> URL {
        directoryURL.appendingPathComponent(
            "\(try fileName(for: sessionID)).lock",
            isDirectory: false
        )
    }

    private func fileName(for sessionID: SessionID) throws -> String {
        try encoder.encode(sessionID)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
