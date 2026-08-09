import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore

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

    private let backend: LiveGroqCredentialBackend
    private let verificationPolicy = CredentialSaveVerificationPolicy()
    /// Intentionally actor-local and non-Codable. This value has no Adapter
    /// capable of writing it to disk, diagnostics, manifests, or preferences.
    private var credentialUntilQuit: String?

    public init() {
        let keychain = KeychainStore(service: Self.keychainService)
        backend = LiveGroqCredentialBackend(
            read: { try keychain.value(for: .groqAPIKey) },
            save: { try keychain.set($0, for: .groqAPIKey) },
            remove: { try keychain.remove(.groqAPIKey) }
        )
    }

    init(backend: LiveGroqCredentialBackend) {
        self.backend = backend
    }

    public func read() throws -> String? {
        if let credentialUntilQuit {
            return credentialUntilQuit
        }
        do {
            if let keychainCredential = normalized(try backend.read()) {
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
    }

    /// Uses a credential only in this actor's process memory. It never calls
    /// the Keychain backend or any serialization/logging Adapter.
    public func useUntilQuit(_ value: String) throws {
        guard let normalized = normalized(value) else {
            throw LiveGroqCredentialStoreError.emptyCredential
        }
        credentialUntilQuit = normalized
    }

    public func remove() throws {
        credentialUntilQuit = nil
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
            if normalized(try backend.read()) != nil {
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
}

struct LiveGroqCredentialBackend: Sendable {
    let read: @Sendable () throws -> String?
    let save: @Sendable (String) throws -> Void
    let remove: @Sendable () throws -> Void
}
