import Foundation
import XCTest

@testable import InterviewArcLiveHostedClient

final class LiveIntegrationTokenStoreTests: XCTestCase {
    func testUsesDedicatedLiveIntegrationKeychainNamespace() {
        XCTAssertEqual(
            LiveIntegrationTokenStore.keychainService,
            "dev.interviewarc.live.integration"
        )
        XCTAssertEqual(
            LiveIntegrationTokenStore.keychainAccount,
            "interview-arc-personal-integration-token"
        )
        XCTAssertNotEqual(
            LiveIntegrationTokenStore.keychainService,
            "dev.interviewarc.live"
        )
    }

    func testSaveVerifiesReadbackAndFingerprintNeverContainsToken() async throws {
        let fixture = TokenBackendFixture()
        let store = LiveIntegrationTokenStore(backend: fixture.backend)

        let initialReadiness = await store.readiness()
        XCTAssertEqual(initialReadiness, .missing)
        try await store.saveAndVerify("  public-test-integration-token  ")

        let readiness = await store.readiness()
        let token = try await store.readIntegrationToken()
        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(token, "public-test-integration-token")
        let fingerprint = try await store.credentialFingerprint()
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertFalse(fingerprint.contains("public-test-integration-token"))
    }

    func testUntilQuitDoesNotWriteKeychainAndRemovalPreservesNoSecret() async throws {
        let fixture = TokenBackendFixture()
        let store = LiveIntegrationTokenStore(backend: fixture.backend)

        try await store.useUntilQuit("ephemeral-test-token")

        let readiness = await store.readiness()
        let token = try await store.readIntegrationToken()
        XCTAssertEqual(readiness, .readyUntilQuit)
        XCTAssertEqual(token, "ephemeral-test-token")
        XCTAssertEqual(fixture.saveCount, 0)

        try await store.remove()
        let removedReadiness = await store.readiness()
        XCTAssertEqual(removedReadiness, .missing)
        XCTAssertNil(fixture.value)
    }

    func testFailedVerificationRestoresPreviousToken() async throws {
        let fixture = TokenBackendFixture(
            value: "previous-token",
            persistsWrites: false
        )
        let store = LiveIntegrationTokenStore(backend: fixture.backend)

        do {
            try await store.saveAndVerify("replacement-token")
            XCTFail("Expected verification failure")
        } catch let error as LiveIntegrationTokenStoreError {
            XCTAssertEqual(error, .verificationFailed)
        }
        XCTAssertEqual(fixture.value, "previous-token")
    }
}

private final class TokenBackendFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    private let persistsWrites: Bool
    private(set) var saveCount = 0

    var value: String? { lock.withLock { storedValue } }

    init(value: String? = nil, persistsWrites: Bool = true) {
        storedValue = value
        self.persistsWrites = persistsWrites
    }

    var backend: LiveIntegrationTokenBackend {
        LiveIntegrationTokenBackend(
            read: { [weak self] in self?.value },
            save: { [weak self] value in
                self?.lock.withLock {
                    self?.saveCount += 1
                    if self?.persistsWrites == true { self?.storedValue = value }
                }
            },
            remove: { [weak self] in
                self?.lock.withLock { self?.storedValue = nil }
            }
        )
    }
}
