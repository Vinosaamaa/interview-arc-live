import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore
import Security

public enum LiveGroqCredentialReadiness: Equatable, Sendable {
    /// A durable Keychain credential is available.
    case ready
    /// The explicit process-memory credential is active and will disappear
    /// when this app process exits.
    case readyUntilQuit
    case missing
    case keychainUnavailable
}

public enum LiveGroqCredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyCredential
    case missingCredential
    case keychainUnavailable
    case verificationFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .emptyCredential:
            "Enter a Groq API key before saving."
        case .missingCredential:
            "Interview Arc Live does not have a Groq API key."
        case .keychainUnavailable:
            "macOS Keychain is unavailable. Use a key until quit or try again."
        case .verificationFailed:
            "Interview Arc Live could not verify the saved Groq API key."
        case .rollbackFailed:
            "Keychain may still contain the submitted Groq API key. Remove or replace it before retrying."
        }
    }
}

public actor LiveGroqCredentialStore: GroqCredentialReading {
    public static let keychainService = "dev.interviewarc.live"
    public static let keychainAccount = "groq-api-key"

    private let backend: LiveGroqCredentialBackend
    private let verificationPolicy = CredentialSaveVerificationPolicy()
    /// Intentionally actor-local and non-Codable. This value has no Adapter
    /// capable of writing it to disk, diagnostics, manifests, or preferences.
    private var credentialUntilQuit: String?
    /// Reuse an authorized read within this store instead of reopening Keychain
    /// for each segment and endpoint request. Never persisted or shared.
    private var cachedKeychainCredential: String?

    public init() {
        backend = Self.securityBackend()
    }

    init(backend: LiveGroqCredentialBackend) {
        self.backend = backend
    }

    public func read() throws -> String? {
        if let credentialUntilQuit {
            return credentialUntilQuit
        }
        if let cachedKeychainCredential { return cachedKeychainCredential }
        do {
            if let keychainCredential = normalized(try backend.read()) {
                cachedKeychainCredential = keychainCredential
                return keychainCredential
            }
            return nil
        } catch {
            throw LiveGroqCredentialStoreError.keychainUnavailable
        }
    }

    public func readGroqCredential() throws -> String {
        guard let value = try read(), !value.isEmpty else {
            throw LiveGroqCredentialStoreError.missingCredential
        }
        return value
    }

    public func saveAndVerify(_ value: String) throws {
        guard let normalized = normalized(value) else {
            throw LiveGroqCredentialStoreError.emptyCredential
        }

        cachedKeychainCredential = nil
        let previousValue: String?
        do {
            previousValue = try backend.read()
        } catch {
            throw LiveGroqCredentialStoreError.keychainUnavailable
        }

        let retrieved: String?
        do {
            try backend.save(normalized)
            retrieved = try backend.read()
        } catch {
            try restoreKeychain(previousValue)
            throw LiveGroqCredentialStoreError.keychainUnavailable
        }
        guard verificationPolicy.isVerified(
            submittedValue: normalized,
            retrievedValue: retrieved
        ) else {
            try restoreKeychain(previousValue)
            throw LiveGroqCredentialStoreError.verificationFailed
        }
        credentialUntilQuit = nil
        cachedKeychainCredential = normalized
    }

    /// Uses a credential only in this actor's process memory. It never calls
    /// the Keychain backend or any serialization/logging Adapter.
    public func useUntilQuit(_ value: String) throws {
        guard let normalized = normalized(value) else {
            throw LiveGroqCredentialStoreError.emptyCredential
        }
        cachedKeychainCredential = nil
        credentialUntilQuit = normalized
    }

    public func remove() throws {
        credentialUntilQuit = nil
        cachedKeychainCredential = nil
        do {
            try backend.remove()
        } catch {
            throw LiveGroqCredentialStoreError.keychainUnavailable
        }
    }

    public func readiness() throws -> LiveGroqCredentialReadiness {
        if credentialUntilQuit != nil {
            return .readyUntilQuit
        }
        do {
            if try read() != nil {
                return .ready
            }
            return .missing
        } catch {
            return .keychainUnavailable
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func restoreKeychain(_ previousValue: String?) throws {
        do {
            if let previousValue {
                try backend.save(previousValue)
                guard verificationPolicy.isVerified(
                    submittedValue: previousValue,
                    retrievedValue: try backend.read(),
                    permitsEmpty: true
                ) else {
                    throw LiveGroqCredentialStoreError.rollbackFailed
                }
            } else {
                try backend.remove()
                guard normalized(try backend.read()) == nil else {
                    throw LiveGroqCredentialStoreError.rollbackFailed
                }
            }
        } catch let error as LiveGroqCredentialStoreError {
            throw error
        } catch {
            throw LiveGroqCredentialStoreError.rollbackFailed
        }
    }

    private static func securityBackend() -> LiveGroqCredentialBackend {
        LiveGroqCredentialBackend(
            read: {
                var query = baseQuery()
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                return try LiveGenericPasswordRead.value(status: status, item: item)
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
                        throw LiveGroqCredentialStoreError.keychainUnavailable
                    }
                } else if status != errSecSuccess {
                    throw LiveGroqCredentialStoreError.keychainUnavailable
                }
            },
            remove: {
                let status = SecItemDelete(baseQuery() as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw LiveGroqCredentialStoreError.keychainUnavailable
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

enum LiveGenericPasswordRead: Sendable {
    /// Maps a `MatchLimitOne` generic-password read. `errSecItemNotFound` is a
    /// missing item, not Keychain unavailability. Do not use `MatchLimitAll`.
    static func value(status: OSStatus, item: CFTypeRef?) throws -> String? {
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw LiveGroqCredentialStoreError.keychainUnavailable
        }
        return value
    }
}

struct LiveGroqCredentialBackend: Sendable {
    let read: @Sendable () throws -> String?
    let save: @Sendable (String) throws -> Void
    let remove: @Sendable () throws -> Void
}
