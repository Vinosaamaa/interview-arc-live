import Foundation
import XCTest

@testable import InterviewArcLiveVoiceAdapter

@MainActor
final class LiveGroqCredentialStoreTests: XCTestCase {
    func testLiveUsesAServiceDistinctFromVoice() {
        XCTAssertEqual(
            LiveGroqCredentialStore.keychainService,
            "dev.interviewarc.live"
        )
        XCTAssertNotEqual(
            LiveGroqCredentialStore.keychainService,
            "dev.interviewarc.voice"
        )
    }

    func testSaveVerifiesReadbackAndReportsReadiness() async throws {
        let fixture = CredentialMemoryFixture()
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        let initialReadiness = try await store.readiness()
        XCTAssertEqual(initialReadiness, .missing)
        try await store.saveAndVerify("  public-test-key  ")

        let readback = try await store.read()
        let requiredReadback = try await store.readGroqCredential()
        let readiness = try await store.readiness()
        XCTAssertEqual(readback, "public-test-key")
        XCTAssertEqual(requiredReadback, "public-test-key")
        XCTAssertEqual(readiness, .ready)
    }

    func testExplicitUntilQuitCredentialOverridesKeychainForThisStore() async throws {
        let fixture = CredentialMemoryFixture(value: "durable-test-key")
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        try await store.useUntilQuit("ephemeral-test-key")

        let active = try await store.readGroqCredential()
        let readiness = try await store.readiness()
        XCTAssertEqual(active, "ephemeral-test-key")
        XCTAssertEqual(readiness, .readyUntilQuit)
        XCTAssertEqual(fixture.saveCount, 0)

        try await store.saveAndVerify("replacement-durable-key")
        let savedCredential = try await store.readGroqCredential()
        let savedReadiness = try await store.readiness()
        XCTAssertEqual(savedCredential, "replacement-durable-key")
        XCTAssertEqual(savedReadiness, .ready)
    }

    func testUnavailableKeychainCanUseProcessMemoryWithoutWritingSecret() async throws {
        let fixture = CredentialMemoryFixture(keychainAvailable: false)
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        let unavailable = try await store.readiness()
        XCTAssertEqual(unavailable, .keychainUnavailable)
        do {
            _ = try await store.readGroqCredential()
            XCTFail("Expected unavailable Keychain to be distinguishable")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .keychainUnavailable)
        }

        try await store.useUntilQuit("  ephemeral-test-key  ")

        let readiness = try await store.readiness()
        let active = try await store.readGroqCredential()
        XCTAssertEqual(readiness, .readyUntilQuit)
        XCTAssertEqual(active, "ephemeral-test-key")
        XCTAssertEqual(fixture.saveCount, 0)
        XCTAssertNil(fixture.value)
        XCTAssertFalse(String(describing: readiness).contains("ephemeral-test-key"))
        XCTAssertFalse(
            LiveGroqCredentialStoreError.keychainUnavailable.localizedDescription
                .contains("ephemeral-test-key")
        )

        let relaunchedStore = LiveGroqCredentialStore(backend: fixture.backend)
        let relaunchedReadiness = try await relaunchedStore.readiness()
        XCTAssertEqual(relaunchedReadiness, .keychainUnavailable)
        do {
            _ = try await relaunchedStore.readGroqCredential()
            XCTFail("A new process store must not inherit the until-quit credential")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .keychainUnavailable)
        }
    }

    func testMissingKeychainAndUntilQuitCredentialHaveDistinctReadiness() async throws {
        let fixture = CredentialMemoryFixture()
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        let missing = try await store.readiness()
        XCTAssertEqual(missing, .missing)
        try await store.useUntilQuit("ephemeral-test-key")
        let untilQuit = try await store.readiness()
        XCTAssertEqual(untilQuit, .readyUntilQuit)
    }

    func testEmptyCredentialIsRejectedWithoutWriting() async throws {
        let fixture = CredentialMemoryFixture()
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        do {
            try await store.saveAndVerify("  \n")
            XCTFail("Expected an empty credential to fail")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .emptyCredential)
        }

        XCTAssertNil(fixture.value)

        do {
            try await store.useUntilQuit("  \n")
            XCTFail("Expected an empty process credential to fail")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .emptyCredential)
        }
        XCTAssertEqual(fixture.saveCount, 0)
    }

    func testFailedReadbackDoesNotClaimCredentialWasSaved() async throws {
        let fixture = CredentialMemoryFixture(persistsWrites: false)
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        do {
            try await store.saveAndVerify("public-test-key")
            XCTFail("Expected verification to fail")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .verificationFailed)
        }
    }

    func testKeychainWriteFailureReturnsSafeUnavailableError() async throws {
        let fixture = CredentialMemoryFixture(keychainAvailable: false)
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        do {
            try await store.saveAndVerify("public-test-key")
            XCTFail("Expected unavailable Keychain save to fail")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .keychainUnavailable)
            XCTAssertFalse(error.localizedDescription.contains("public-test-key"))
        }
    }

    func testRemoveClearsCredential() async throws {
        let fixture = CredentialMemoryFixture(value: "public-test-key")
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        try await store.remove()

        let readiness = try await store.readiness()
        XCTAssertEqual(readiness, .missing)
        XCTAssertNil(fixture.value)
    }
}

private final class CredentialMemoryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    private let persistsWrites: Bool
    private let keychainAvailable: Bool
    private var saves = 0

    init(
        value: String? = nil,
        persistsWrites: Bool = true,
        keychainAvailable: Bool = true
    ) {
        storedValue = value
        self.persistsWrites = persistsWrites
        self.keychainAvailable = keychainAvailable
    }

    var value: String? {
        lock.withLock { storedValue }
    }

    var saveCount: Int {
        lock.withLock { saves }
    }

    var backend: LiveGroqCredentialBackend {
        LiveGroqCredentialBackend(
            read: { [self] in
                try lock.withLock {
                    guard keychainAvailable else { throw CredentialFixtureError.unavailable }
                    return storedValue
                }
            },
            save: { [self] value in
                try lock.withLock {
                    guard keychainAvailable else { throw CredentialFixtureError.unavailable }
                    saves += 1
                    if persistsWrites { storedValue = value }
                }
            },
            remove: { [self] in
                try lock.withLock {
                    guard keychainAvailable else { throw CredentialFixtureError.unavailable }
                    storedValue = nil
                }
            }
        )
    }
}

private enum CredentialFixtureError: Error {
    case unavailable
}
