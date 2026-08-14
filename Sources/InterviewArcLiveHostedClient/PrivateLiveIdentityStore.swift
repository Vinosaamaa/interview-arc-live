import Foundation

public struct LiveInstallationIdentity: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let holderId: String

    public init(holderId: String) {
        self.schemaVersion = 1
        self.holderId = holderId
    }
}

public actor PrivateLiveIdentityStore {
    private let store: PrivateLiveJSONStore
    private var cachedIdentity: LiveInstallationIdentity?

    public init() throws {
        let (hierarchy, file) = try PrivateLiveJSONStore.hostedHierarchy(
            leaf: "installation-identity.json"
        )
        store = PrivateLiveJSONStore(
            directoryHierarchy: hierarchy,
            fileURL: file
        )
    }

    public init(directoryURL: URL) {
        store = PrivateLiveJSONStore(
            directoryHierarchy: [directoryURL],
            fileURL: directoryURL.appendingPathComponent(
                "installation-identity.json"
            )
        )
    }

    public func loadOrCreate() throws -> LiveInstallationIdentity {
        if let cachedIdentity { return cachedIdentity }
        if let identity = try store.load(LiveInstallationIdentity.self) {
            guard Self.isUUIDv4(identity.holderId) else {
                throw PrivateLiveStorageError.unsafePath
            }
            cachedIdentity = identity
            return identity
        }
        let identity = LiveInstallationIdentity(
            holderId: UUID().uuidString.lowercased()
        )
        try store.save(identity)
        cachedIdentity = identity
        return identity
    }

    private static func isUUIDv4(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        let normalized = uuid.uuidString.lowercased()
        return normalized == value.lowercased()
            && normalized.split(separator: "-").count == 5
            && normalized.dropFirst(14).first == "4"
    }
}
