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

    init(value: String? = nil, persistsWrites: Bool = true) {
        storedValue = value
        self.persistsWrites = persistsWrites
    }

    var value: String? {
        lock.withLock { storedValue }
    }

    var backend: LiveGroqCredentialBackend {
        LiveGroqCredentialBackend(
            read: { [self] in lock.withLock { storedValue } },
            save: { [self] value in
                lock.withLock {
                    if persistsWrites { storedValue = value }
                }
            },
            remove: { [self] in lock.withLock { storedValue = nil } }
        )
    }
}
