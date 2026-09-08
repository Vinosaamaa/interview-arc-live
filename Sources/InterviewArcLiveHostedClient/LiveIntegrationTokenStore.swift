import CryptoKit
import Foundation
import Security

public enum LiveIntegrationTokenReadiness: Equatable, Sendable {
    case ready
    case readyUntilQuit
    case missing
    case keychainUnavailable
}

public enum LiveIntegrationTokenStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyToken
    case missingToken
    case keychainUnavailable
    case verificationFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .emptyToken:
            "Paste an Interview Arc integration token before continuing."
        case .missingToken:
            "Interview Arc Live is not connected to Interview Arc."
        case .keychainUnavailable:
            "macOS Keychain is unavailable. Use the token until quit or try again."
        case .verificationFailed:
            "Interview Arc Live could not verify the saved integration token."
        case .rollbackFailed:
            "Keychain may still contain the submitted integration token. Remove or replace it before retrying."
        }
    }
}

public protocol LiveIntegrationTokenReading: Sendable {
    func readIntegrationToken() async throws -> String
    func credentialFingerprint() async throws -> String
}

public actor LiveIntegrationTokenStore: LiveIntegrationTokenReading {
    public static let keychainService = "dev.interviewarc.live.integration"
    public static let keychainAccount = "interview-arc-personal-integration-token"

    private let backend: LiveIntegrationTokenBackend
    private var tokenUntilQuit: String?
    /// Actor-local reuse after a successful authorized read. This never changes
    /// Keychain access controls or persists a second copy of the token.
    private var cachedKeychainToken: String?

    public init() {
        backend = Self.securityBackend()
    }

    init(backend: LiveIntegrationTokenBackend) {
        self.backend = backend
    }

    public func readiness() -> LiveIntegrationTokenReadiness {
        if tokenUntilQuit != nil { return .readyUntilQuit }
        do {
            return try readSavedToken() == nil ? .missing : .ready
        } catch {
            return .keychainUnavailable
        }
    }

    public func readIntegrationToken() throws -> String {
        if let tokenUntilQuit { return tokenUntilQuit }
        do {
            guard let value = try readSavedToken() else {
                throw LiveIntegrationTokenStoreError.missingToken
            }
            return value
        } catch let error as LiveIntegrationTokenStoreError {
            throw error
        } catch {
            throw LiveIntegrationTokenStoreError.keychainUnavailable
        }
    }

    public func credentialFingerprint() throws -> String {
        let token = try readIntegrationToken()
        return SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func saveAndVerify(_ value: String) throws {
        guard let submitted = normalized(value) else {
            throw LiveIntegrationTokenStoreError.emptyToken
        }
        cachedKeychainToken = nil
        let previous: String?
        do { previous = try backend.read() }
        catch { throw LiveIntegrationTokenStoreError.keychainUnavailable }

        do {
            try backend.save(submitted)
            guard normalized(try backend.read()) == submitted else {
                try restore(previous)
                throw LiveIntegrationTokenStoreError.verificationFailed
            }
            tokenUntilQuit = nil
            cachedKeychainToken = submitted
        } catch let error as LiveIntegrationTokenStoreError {
            throw error
        } catch {
            try restore(previous)
            throw LiveIntegrationTokenStoreError.keychainUnavailable
        }
    }

    public func useUntilQuit(_ value: String) throws {
        guard let value = normalized(value) else {
            throw LiveIntegrationTokenStoreError.emptyToken
        }
        cachedKeychainToken = nil
        tokenUntilQuit = value
    }

    public func remove() throws {
        tokenUntilQuit = nil
        cachedKeychainToken = nil
        do { try backend.remove() }
        catch { throw LiveIntegrationTokenStoreError.keychainUnavailable }
    }

    private func readSavedToken() throws -> String? {
        if let cachedKeychainToken { return cachedKeychainToken }
        let value = normalized(try backend.read())
        cachedKeychainToken = value
        return value
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func restore(_ previous: String?) throws {
        do {
            if let previous { try backend.save(previous) }
            else { try backend.remove() }
            guard normalized(try backend.read()) == normalized(previous) else {
                throw LiveIntegrationTokenStoreError.rollbackFailed
            }
        } catch let error as LiveIntegrationTokenStoreError {
            throw error
        } catch {
            throw LiveIntegrationTokenStoreError.rollbackFailed
        }
    }

    private static func securityBackend() -> LiveIntegrationTokenBackend {
        return LiveIntegrationTokenBackend(
            read: {
                var query = baseQuery()
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess,
                      let data = item as? Data,
                      let value = String(data: data, encoding: .utf8) else {
                    throw LiveIntegrationTokenStoreError.keychainUnavailable
                }
                return value
            },
            save: { value in
                let data = Data(value.utf8)
                let update = [kSecValueData as String: data]
                let base = baseQuery()
                let status = SecItemUpdate(
                    base as CFDictionary,
                    update as CFDictionary
                )
                if status == errSecItemNotFound {
                    var insert = base
                    insert[kSecValueData as String] = data
                    insert[kSecAttrAccessible as String] =
                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                        throw LiveIntegrationTokenStoreError.keychainUnavailable
                    }
                } else if status != errSecSuccess {
                    throw LiveIntegrationTokenStoreError.keychainUnavailable
                }
            },
            remove: {
                let base = baseQuery()
                let status = SecItemDelete(base as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw LiveIntegrationTokenStoreError.keychainUnavailable
                }
            }
        )
    }

    private nonisolated static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }
}

struct LiveIntegrationTokenBackend: Sendable {
    let read: @Sendable () throws -> String?
    let save: @Sendable (String) throws -> Void
    let remove: @Sendable () throws -> Void
}
