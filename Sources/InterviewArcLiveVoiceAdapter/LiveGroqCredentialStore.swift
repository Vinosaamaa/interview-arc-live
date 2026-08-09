import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore

public enum LiveGroqCredentialReadiness: Equatable, Sendable {
    case ready
    case missing
}

public enum LiveGroqCredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyCredential
    case missingCredential
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .emptyCredential:
            "Enter a Groq API key before saving."
        case .missingCredential:
            "Interview Arc Live does not have a Groq API key in Keychain."
        case .verificationFailed:
            "Interview Arc Live could not verify the saved Groq API key."
        }
    }
}

public actor LiveGroqCredentialStore: GroqCredentialReading {
    public static let keychainService = "dev.interviewarc.live"

    private let backend: LiveGroqCredentialBackend
    private let verificationPolicy = CredentialSaveVerificationPolicy()

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
        try backend.read()
    }

    public func readGroqCredential() throws -> String {
        guard let value = try read(), !value.isEmpty else {
            throw LiveGroqCredentialStoreError.missingCredential
        }
        return value
    }

    public func saveAndVerify(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LiveGroqCredentialStoreError.emptyCredential
        }

        try backend.save(normalized)
        guard verificationPolicy.isVerified(
            submittedValue: normalized,
            retrievedValue: try backend.read()
        ) else {
            throw LiveGroqCredentialStoreError.verificationFailed
        }
    }

    public func remove() throws {
        try backend.remove()
    }

    public func readiness() throws -> LiveGroqCredentialReadiness {
        guard let value = try read(),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missing
        }
        return .ready
    }
}

struct LiveGroqCredentialBackend: Sendable {
    let read: @Sendable () throws -> String?
    let save: @Sendable (String) throws -> Void
    let remove: @Sendable () throws -> Void
}
