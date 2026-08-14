import Darwin
import Foundation
import XCTest

@testable import InterviewArcLiveHostedClient

final class PrivateLiveStoresTests: XCTestCase {
    func testIdentityIsStableUUIDv4WithPrivateModes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateLiveIdentityStore(directoryURL: directory)

        let first = try await store.loadOrCreate()
        let restored = try await PrivateLiveIdentityStore(
            directoryURL: directory
        ).loadOrCreate()

        XCTAssertEqual(first, restored)
        XCTAssertNotNil(UUID(uuidString: first.holderId))
        XCTAssertEqual(first.holderId.dropFirst(14).first, "4")
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(
            try permissions(
                directory.appendingPathComponent("installation-identity.json")
            ),
            0o600
        )
    }

    func testOutboxPersistsStableDigestAndRejectsChangedOperationReuse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateLiveOutboxStore(directoryURL: directory)
        let record = outboxRecord(body: Data(#"{"operationId":"op-1"}"#.utf8))

        try await store.prepare(record)
        let restored = try await PrivateLiveOutboxStore(
            directoryURL: directory
        ).records(credentialFingerprint: fingerprint)
        XCTAssertEqual(restored, [record])
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(
            try permissions(directory.appendingPathComponent("\(fingerprint).json")),
            0o600
        )

        do {
            try await store.prepare(
                outboxRecord(body: Data(#"{"operationId":"op-1","changed":true}"#.utf8))
            )
            XCTFail("Expected changed operation identity to fail closed")
        } catch let error as PrivateLiveOutboxStoreError {
            XCTAssertEqual(error, .operationIdentityConflict)
        }
    }

    func testCredentialChangeQuarantinesRatherThanReassignsPendingRecords() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateLiveOutboxStore(directoryURL: directory)
        try await store.prepare(outboxRecord(body: Data("one".utf8)))

        let replacementFingerprint = String(repeating: "b", count: 64)
        let hasQuarantine = try await store.hasQuarantinedPartitions(
            excluding: replacementFingerprint
        )
        let replacementRecords = try await store.records(
            credentialFingerprint: replacementFingerprint
        )
        XCTAssertTrue(hasQuarantine)
        XCTAssertTrue(replacementRecords.isEmpty)
    }

    func testOutboxRecoveryOrderHonorsDependenciesBeforeTimestampAndIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateLiveOutboxStore(directoryURL: directory)
        let parent = outboxRecord(
            operationID: "z-parent",
            dependencyOperationID: nil,
            createdAt: 5
        )
        let child = outboxRecord(
            operationID: "a-child",
            dependencyOperationID: parent.operationId,
            createdAt: 1
        )

        try await store.prepare(child)
        try await store.prepare(parent)

        let restored = try await store.records(
            credentialFingerprint: fingerprint
        )
        XCTAssertEqual(restored.map(\.operationId), ["z-parent", "a-child"])
    }

    func testOutboxDependencyCycleFailsClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateLiveOutboxStore(directoryURL: directory)
        try await store.prepare(
            outboxRecord(
                operationID: "operation-a",
                dependencyOperationID: "operation-b",
                createdAt: 1
            )
        )
        try await store.prepare(
            outboxRecord(
                operationID: "operation-b",
                dependencyOperationID: "operation-a",
                createdAt: 2
            )
        )

        do {
            _ = try await store.records(credentialFingerprint: fingerprint)
            XCTFail("A cyclic outbox must stop automatic recovery")
        } catch let error as PrivateLiveOutboxStoreError {
            XCTAssertEqual(error, .dependencyCycle)
        }
    }

    func testClipStoreVerifiesExactPrivateBytesAndDetectsTampering() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateLiveClipStore(directoryURL: directory)
        let bytes = Data("public audio fixture".utf8)
        let intent = try await store.persist(
            clipID: "clip-1",
            candidateTurnID: "turn-1",
            mimeType: "audio/wav",
            data: bytes
        )

        let verified = try await store.verify(intent)
        XCTAssertEqual(verified, bytes)
        XCTAssertEqual(
            try permissions(directory.appendingPathComponent(intent.contentReference)),
            0o600
        )

        try Data("changed".utf8).write(
            to: directory.appendingPathComponent(intent.contentReference),
            options: [.atomic]
        )
        do {
            _ = try await store.verify(intent)
            XCTFail("Expected tampered bytes to fail closed")
        } catch let error as HostedPracticeSessionError {
            XCTAssertEqual(error, .invalidClip)
        }
    }

    private var fingerprint: String { String(repeating: "a", count: 64) }

    private func outboxRecord(body: Data) -> LiveOutboxRecord {
        outboxRecord(
            operationID: "op-1",
            dependencyOperationID: nil,
            createdAt: 1,
            body: body
        )
    }

    private func outboxRecord(
        operationID: String,
        dependencyOperationID: String?,
        createdAt: LiveEpochMilliseconds,
        body: Data? = nil
    ) -> LiveOutboxRecord {
        LiveOutboxRecord(
            operationId: operationID,
            operation: "command.start",
            pathSuffix: "commands",
            activityId: "activity-1",
            workbenchId: "workbench-1",
            holderId: "00000000-0000-4000-8000-000000000001",
            holderSessionId: "room-1",
            fencingToken: 1,
            dependencyOperationId: dependencyOperationID,
            canonicalBody: body ?? Data("{\"operationId\":\"(operationID)\"}".utf8),
            credentialFingerprint: fingerprint,
            createdAt: createdAt
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "live-hosted-store-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
