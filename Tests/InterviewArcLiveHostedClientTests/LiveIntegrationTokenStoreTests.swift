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

    func testAuthorizedReadIsReusedAcrossRequestsAndFingerprints() async throws {
        let fixture = TokenBackendFixture(value: "saved-token", failingReadCalls: [2])
        let store = LiveIntegrationTokenStore(backend: fixture.backend)
        let readiness = await store.readiness()
        XCTAssertEqual(readiness, .ready)
        for _ in 0..<3 {
            let value = try await store.readIntegrationToken()
            let fingerprint = try await store.credentialFingerprint()
            let nextReadiness = await store.readiness()
            XCTAssertEqual(value, "saved-token")
            XCTAssertEqual(fingerprint.count, 64)
            XCTAssertEqual(nextReadiness, .ready)
        }
        XCTAssertEqual(fixture.readCount, 1)

        let newStore = LiveIntegrationTokenStore(backend: fixture.backend)
        let newReadiness = await newStore.readiness()
        XCTAssertEqual(newReadiness, .keychainUnavailable)
        XCTAssertEqual(fixture.readCount, 2)
    }

    func testReplacementAndRemovalDoNotRetainCachedToken() async throws {
        let fixture = TokenBackendFixture(value: "old-token")
        let store = LiveIntegrationTokenStore(backend: fixture.backend)
        _ = try await store.readIntegrationToken()
        try await store.useUntilQuit("temporary-token")
        let temporary = try await store.readIntegrationToken()
        XCTAssertEqual(temporary, "temporary-token")
        try await store.saveAndVerify("replacement-token")
        let replacement = try await store.readIntegrationToken()
        let readiness = await store.readiness()
        XCTAssertEqual(replacement, "replacement-token")
        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(fixture.readCount, 3)
        try await store.remove()
        let removed = await store.readiness()
        XCTAssertEqual(removed, .missing)
        XCTAssertEqual(fixture.readCount, 4)
    }

    func testFailedVerificationInvalidatesPreviouslyCachedToken() async throws {
        let fixture = TokenBackendFixture(value: "old-token", persistsWrites: false)
        let store = LiveIntegrationTokenStore(backend: fixture.backend)
        _ = try await store.readIntegrationToken()
        do {
            try await store.saveAndVerify("replacement-token")
            XCTFail("Expected actual readback to reject the replacement")
        } catch let error as LiveIntegrationTokenStoreError {
            XCTAssertEqual(error, .verificationFailed)
        }
        let restored = try await store.readIntegrationToken()
        XCTAssertEqual(restored, "old-token")
        XCTAssertEqual(fixture.readCount, 5)
    }

    func testFailedRemovalDoesNotKeepServingCachedToken() async throws {
        let fixture = TokenBackendFixture(
            value: "old-token", failingReadCalls: [2], removeFails: true
        )
        let store = LiveIntegrationTokenStore(backend: fixture.backend)
        _ = try await store.readIntegrationToken()
        do {
            try await store.remove()
            XCTFail("Expected removal failure")
        } catch let error as LiveIntegrationTokenStoreError {
            XCTAssertEqual(error, .keychainUnavailable)
        }
        let readiness = await store.readiness()
        XCTAssertEqual(readiness, .keychainUnavailable)
        XCTAssertEqual(fixture.readCount, 2)
    }

    func testMissingOrDeniedReadDoesNotPreventExplicitRetry() async throws {
        let fixture = TokenBackendFixture(failingReadCalls: [1])
        let store = LiveIntegrationTokenStore(backend: fixture.backend)
        let denied = await store.readiness()
        XCTAssertEqual(denied, .keychainUnavailable)
        let missing = await store.readiness()
        XCTAssertEqual(missing, .missing)
        try fixture.backend.save("new-token")
        let value = try await store.readIntegrationToken()
        XCTAssertEqual(value, "new-token")
        XCTAssertEqual(fixture.readCount, 3)
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
    private let failingReadCalls: Set<Int>
    private let removeFails: Bool
    private var reads = 0
    private(set) var saveCount = 0

    var value: String? { lock.withLock { storedValue } }
    var readCount: Int { lock.withLock { reads } }

    init(
        value: String? = nil,
        persistsWrites: Bool = true,
        failingReadCalls: Set<Int> = [],
        removeFails: Bool = false
    ) {
        storedValue = value
        self.persistsWrites = persistsWrites
        self.failingReadCalls = failingReadCalls
        self.removeFails = removeFails
    }

    var backend: LiveIntegrationTokenBackend {
        LiveIntegrationTokenBackend(
            read: { [self] in
                try lock.withLock {
                    reads += 1
                    if failingReadCalls.contains(reads) { throw TokenFixtureError.unavailable }
                    return storedValue
                }
            },
            save: { [weak self] value in
                self?.lock.withLock {
                    self?.saveCount += 1
                    if self?.persistsWrites == true { self?.storedValue = value }
                }
            },
            remove: { [self] in
                try lock.withLock {
                    if removeFails { throw TokenFixtureError.unavailable }
                    storedValue = nil
                }
            }
        )
    }
}

private enum TokenFixtureError: Error {
    case unavailable
}
