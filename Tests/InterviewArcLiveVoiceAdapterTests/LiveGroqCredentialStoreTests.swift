import Foundation
import Security
import XCTest

@testable import InterviewArcLiveVoiceAdapter

@MainActor
final class LiveGroqCredentialStoreTests: XCTestCase {
    func testLiveUsesAServiceDistinctFromVoice() {
        XCTAssertEqual(
            LiveGroqCredentialStore.keychainService,
            "dev.interviewarc.live"
        )
        XCTAssertEqual(
            LiveGroqCredentialStore.keychainAccount,
            "groq-api-key"
        )
        XCTAssertNotEqual(
            LiveGroqCredentialStore.keychainService,
            "dev.interviewarc.voice"
        )
    }

    func testMissingGenericPasswordIsNotKeychainUnavailable() throws {
        XCTAssertNil(
            try LiveGenericPasswordRead.value(
                status: errSecItemNotFound,
                item: nil
            )
        )
    }

    func testParamStatusFromLegacyMatchAllIsKeychainUnavailable() {
        do {
            _ = try LiveGenericPasswordRead.value(
                status: errSecParam,
                item: nil
            )
            XCTFail("Expected errSecParam to be unavailable, not missing")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .keychainUnavailable)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testSuccessfulGenericPasswordReadReturnsUTF8Value() throws {
        let stored = Data("public-test-key".utf8) as CFTypeRef
        let value = try LiveGenericPasswordRead.value(
            status: errSecSuccess,
            item: stored
        )
        XCTAssertEqual(value, "public-test-key")
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

    func testThrownReadbackRestoresPreviousKeychainValue() async throws {
        let fixture = TransactionCredentialFixture(
            value: "previous-test-key",
            failingReadCalls: [2]
        )
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        do {
            try await store.saveAndVerify("submitted-test-key")
            XCTFail("Expected verification readback to fail")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .keychainUnavailable)
        }

        XCTAssertEqual(fixture.value, "previous-test-key")
        XCTAssertEqual(fixture.saveCount, 2)
    }

    func testMismatchedReadbackRestoresPreviousKeychainValue() async throws {
        let fixture = TransactionCredentialFixture(
            value: "previous-test-key",
            mismatchedReadCalls: [2: "different-test-key"]
        )
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        do {
            try await store.saveAndVerify("submitted-test-key")
            XCTFail("Expected verification mismatch")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .verificationFailed)
        }

        XCTAssertEqual(fixture.value, "previous-test-key")
        XCTAssertEqual(fixture.saveCount, 2)
    }

    func testMismatchedReadbackRemovesNewlyInsertedKeychainValue() async throws {
        let fixture = TransactionCredentialFixture(
            value: nil,
            mismatchedReadCalls: [2: "different-test-key"]
        )
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        do {
            try await store.saveAndVerify("submitted-test-key")
            XCTFail("Expected verification mismatch")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .verificationFailed)
        }

        XCTAssertNil(fixture.value)
    }

    func testFailedRollbackReportsSafePossibleSubmittedValue() async throws {
        let fixture = TransactionCredentialFixture(
            value: nil,
            failingReadCalls: [2],
            removeFails: true
        )
        let store = LiveGroqCredentialStore(backend: fixture.backend)

        do {
            try await store.saveAndVerify("submitted-test-key")
            XCTFail("Expected rollback failure")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .rollbackFailed)
            XCTAssertTrue(error.localizedDescription.contains("may still contain"))
            XCTAssertFalse(error.localizedDescription.contains("submitted-test-key"))
        }
        XCTAssertEqual(fixture.value, "submitted-test-key")
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

    func testAuthorizedReadIsReusedAcrossReadinessAndTranscription() async throws {
        let fixture = TransactionCredentialFixture(
            value: "public-test-key", failingReadCalls: [2]
        )
        let store = LiveGroqCredentialStore(backend: fixture.backend)
        let readiness = try await store.readiness()
        XCTAssertEqual(readiness, .ready)
        for _ in 0..<3 {
            let value = try await store.readGroqCredential()
            let nextReadiness = try await store.readiness()
            XCTAssertEqual(value, "public-test-key")
            XCTAssertEqual(nextReadiness, .ready)
        }
        XCTAssertEqual(fixture.readCount, 1)

        let newStore = LiveGroqCredentialStore(backend: fixture.backend)
        let newReadiness = try await newStore.readiness()
        XCTAssertEqual(newReadiness, .keychainUnavailable)
        XCTAssertEqual(fixture.readCount, 2)
    }

    func testReplacementAndRemovalDoNotRetainCachedCredential() async throws {
        let fixture = TransactionCredentialFixture(value: "old-key")
        let store = LiveGroqCredentialStore(backend: fixture.backend)
        _ = try await store.readGroqCredential()
        try await store.useUntilQuit("temporary-key")
        let temporary = try await store.readGroqCredential()
        XCTAssertEqual(temporary, "temporary-key")
        try await store.saveAndVerify("replacement-key")
        let replacement = try await store.readGroqCredential()
        let readiness = try await store.readiness()
        XCTAssertEqual(replacement, "replacement-key")
        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(fixture.readCount, 3)
        try await store.remove()
        let removed = try await store.read()
        XCTAssertNil(removed)
        XCTAssertEqual(fixture.readCount, 4)
    }

    func testFailedReplacementInvalidatesCacheBeforeReadback() async throws {
        let fixture = TransactionCredentialFixture(
            value: "old-key", mismatchedReadCalls: [3: "wrong-key"]
        )
        let store = LiveGroqCredentialStore(backend: fixture.backend)
        _ = try await store.readGroqCredential()
        do {
            try await store.saveAndVerify("replacement-key")
            XCTFail("Expected the real readback to reject the replacement")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .verificationFailed)
        }
        let restored = try await store.readGroqCredential()
        XCTAssertEqual(restored, "old-key")
        XCTAssertEqual(fixture.readCount, 5)
    }

    func testFailedRemovalDoesNotKeepServingCachedCredential() async throws {
        let fixture = TransactionCredentialFixture(
            value: "old-key", failingReadCalls: [2], removeFails: true
        )
        let store = LiveGroqCredentialStore(backend: fixture.backend)
        _ = try await store.readGroqCredential()
        do {
            try await store.remove()
            XCTFail("Expected removal failure")
        } catch let error as LiveGroqCredentialStoreError {
            XCTAssertEqual(error, .keychainUnavailable)
        }
        let readiness = try await store.readiness()
        XCTAssertEqual(readiness, .keychainUnavailable)
        XCTAssertEqual(fixture.readCount, 2)
    }

    func testMissingCredentialIsReadAgainAfterAnExternalSave() async throws {
        let fixture = CredentialMemoryFixture()
        let store = LiveGroqCredentialStore(backend: fixture.backend)
        let missing = try await store.readiness()
        XCTAssertEqual(missing, .missing)
        try fixture.backend.save("new-key")
        let value = try await store.readGroqCredential()
        XCTAssertEqual(value, "new-key")
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

private final class TransactionCredentialFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    private var reads = 0
    private var saves = 0
    private let failingReadCalls: Set<Int>
    private let mismatchedReadCalls: [Int: String]
    private let removeFails: Bool

    init(
        value: String?,
        failingReadCalls: Set<Int> = [],
        mismatchedReadCalls: [Int: String] = [:],
        removeFails: Bool = false
    ) {
        storedValue = value
        self.failingReadCalls = failingReadCalls
        self.mismatchedReadCalls = mismatchedReadCalls
        self.removeFails = removeFails
    }

    var readCount: Int {
        lock.withLock { reads }
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
                    reads += 1
                    if failingReadCalls.contains(reads) {
                        throw CredentialFixtureError.unavailable
                    }
                    return mismatchedReadCalls[reads] ?? storedValue
                }
            },
            save: { [self] value in
                lock.withLock {
                    saves += 1
                    storedValue = value
                }
            },
            remove: { [self] in
                try lock.withLock {
                    if removeFails {
                        throw CredentialFixtureError.unavailable
                    }
                    storedValue = nil
                }
            }
        )
    }
}
